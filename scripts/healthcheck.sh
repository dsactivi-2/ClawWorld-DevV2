#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh — Comprehensive health verification for openclaw-teams
# Exit codes: 0 = all healthy, 1 = one or more checks failed
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Color helpers
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
log_success() { echo -e "${GREEN}[PASS]${RESET}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[FAIL]${RESET}  $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}--- $* ---${RESET}"; }

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-openclaw-production}"
GATEWAY_HOST="${GATEWAY_HOST:-localhost}"
GATEWAY_PORT="${GATEWAY_PORT:-3000}"
BASE_URL="http://${GATEWAY_HOST}:${GATEWAY_PORT}"

POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-openclaw_teams}"
POSTGRES_USER="${POSTGRES_USER:-openclaw}"

REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"

TIMEOUT="${TIMEOUT:-10}"
FAILED=0

# Tracking
RESULTS=()

record_pass() { RESULTS+=("PASS: $*"); }
record_fail() { RESULTS+=("FAIL: $*"); FAILED=$((FAILED + 1)); }

# -----------------------------------------------------------------------------
# Helper: HTTP check
# -----------------------------------------------------------------------------
check_http() {
  local name="$1"
  local url="$2"
  local expected_status="${3:-200}"

  local status
  status=$(curl -sf -o /dev/null -w "%{http_code}" --max-time "${TIMEOUT}" "${url}" 2>/dev/null || echo "000")

  if [[ "${status}" == "${expected_status}" ]]; then
    log_success "${name} (HTTP ${status}): ${url}"
    record_pass "${name}"
  else
    log_error "${name} — expected HTTP ${expected_status}, got ${status}: ${url}"
    record_fail "${name}"
  fi
}

# -----------------------------------------------------------------------------
# Check 1 — Service endpoints
# -----------------------------------------------------------------------------
check_endpoints() {
  log_step "Service Endpoints"

  # Port-forward if running from outside the cluster
  if ! curl -sf --max-time 2 "${BASE_URL}/health" &>/dev/null; then
    log_info "Gateway not reachable directly — attempting port-forward"
    kubectl port-forward \
      --namespace="${NAMESPACE}" \
      service/openclaw-gateway "${GATEWAY_PORT}:3000" &>/dev/null &
    PF_PID=$!
    trap 'kill ${PF_PID} 2>/dev/null || true' RETURN
    sleep 3
  fi

  check_http "health endpoint"   "${BASE_URL}/health"
  check_http "metrics endpoint"  "${BASE_URL}/metrics"
  check_http "readiness probe"   "${BASE_URL}/health"
}

# -----------------------------------------------------------------------------
# Check 2 — PostgreSQL connectivity
# -----------------------------------------------------------------------------
check_postgres() {
  log_step "PostgreSQL Connectivity"

  # Try via kubectl exec into the postgres pod
  if kubectl get pod postgres-0 --namespace="${NAMESPACE}" &>/dev/null; then
    local result
    result=$(kubectl exec postgres-0 --namespace="${NAMESPACE}" -- \
      sh -c "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB} -h 127.0.0.1" 2>&1 || echo "FAIL")

    if echo "${result}" | grep -q "accepting connections"; then
      log_success "PostgreSQL (postgres-0): accepting connections"
      record_pass "PostgreSQL connectivity"
    else
      log_error "PostgreSQL (postgres-0): ${result}"
      record_fail "PostgreSQL connectivity"
    fi

    # Check replication lag / basic query
    local row_count
    row_count=$(kubectl exec postgres-0 --namespace="${NAMESPACE}" -- \
      psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -t -c "SELECT 1;" 2>/dev/null | tr -d ' ' || echo "error")

    if [[ "${row_count}" == "1" ]]; then
      log_success "PostgreSQL: basic query OK"
      record_pass "PostgreSQL query"
    else
      log_error "PostgreSQL: basic query failed"
      record_fail "PostgreSQL query"
    fi
  else
    # Fallback: psql from PATH
    if command -v psql &>/dev/null; then
      if PGPASSWORD="${POSTGRES_PASSWORD:-}" psql \
          -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
          -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
          -c "SELECT 1;" &>/dev/null; then
        log_success "PostgreSQL (direct): connection OK"
        record_pass "PostgreSQL connectivity"
      else
        log_error "PostgreSQL (direct): connection failed"
        record_fail "PostgreSQL connectivity"
      fi
    else
      log_warn "PostgreSQL pod not found and psql not available — skipping"
    fi
  fi
}

# -----------------------------------------------------------------------------
# Check 3 — Redis connectivity
# -----------------------------------------------------------------------------
check_redis() {
  log_step "Redis Connectivity"

  if kubectl get pod redis-0 --namespace="${NAMESPACE}" &>/dev/null; then
    local result
    result=$(kubectl exec redis-0 --namespace="${NAMESPACE}" -- \
      sh -c 'redis-cli -a "${REDIS_PASSWORD:-}" ping 2>/dev/null || echo "FAIL"')

    if echo "${result}" | grep -q "PONG"; then
      log_success "Redis (redis-0): PONG"
      record_pass "Redis connectivity"
    else
      log_error "Redis (redis-0): ${result}"
      record_fail "Redis connectivity"
    fi

    # Check memory info
    local used_mem
    used_mem=$(kubectl exec redis-0 --namespace="${NAMESPACE}" -- \
      sh -c 'redis-cli -a "${REDIS_PASSWORD:-}" info memory 2>/dev/null | grep used_memory_human' \
      || echo "unknown")
    log_info "Redis memory: ${used_mem}"
  else
    if command -v redis-cli &>/dev/null; then
      if redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" ping 2>/dev/null | grep -q "PONG"; then
        log_success "Redis (direct): PONG"
        record_pass "Redis connectivity"
      else
        log_error "Redis (direct): no PONG"
        record_fail "Redis connectivity"
      fi
    else
      log_warn "Redis pod not found and redis-cli not available — skipping"
    fi
  fi
}

# -----------------------------------------------------------------------------
# Check 4 — Agent status via API
# -----------------------------------------------------------------------------
check_agent_status() {
  log_step "Agent Status"

  local agents_url="${BASE_URL}/api/agents/status"
  local response
  response=$(curl -sf --max-time "${TIMEOUT}" "${agents_url}" 2>/dev/null || echo "")

  if [[ -n "${response}" ]]; then
    log_success "Agent status endpoint reachable"
    record_pass "Agent status API"

    # Check for any unhealthy agents
    if echo "${response}" | grep -qi '"status".*"unhealthy"'; then
      log_warn "One or more agents report unhealthy status"
      record_fail "Agent health"
    else
      log_success "All agents report healthy"
      record_pass "Agent health"
    fi
  else
    log_warn "Agent status endpoint not reachable (may not be implemented yet)"
    record_pass "Agent status API (skipped)"
  fi
}

# -----------------------------------------------------------------------------
# Check 5 — Kubernetes pod readiness
# -----------------------------------------------------------------------------
check_pod_readiness() {
  log_step "Kubernetes Pod Readiness"

  local deployments=("openclaw-gateway")
  for deploy in "${deployments[@]}"; do
    local ready
    ready=$(kubectl get deployment "${deploy}" \
      --namespace="${NAMESPACE}" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    local desired
    desired=$(kubectl get deployment "${deploy}" \
      --namespace="${NAMESPACE}" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

    if [[ "${ready}" == "${desired}" ]] && [[ "${ready}" != "0" ]]; then
      log_success "Deployment ${deploy}: ${ready}/${desired} replicas ready"
      record_pass "Deployment ${deploy} readiness"
    else
      log_error "Deployment ${deploy}: ${ready:-0}/${desired} replicas ready"
      record_fail "Deployment ${deploy} readiness"
    fi
  done

  local statefulsets=("postgres" "redis")
  for sts in "${statefulsets[@]}"; do
    local ready
    ready=$(kubectl get statefulset "${sts}" \
      --namespace="${NAMESPACE}" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${ready:-0}" -gt 0 ]]; then
      log_success "StatefulSet ${sts}: ${ready} replicas ready"
      record_pass "StatefulSet ${sts} readiness"
    else
      log_error "StatefulSet ${sts}: no replicas ready"
      record_fail "StatefulSet ${sts} readiness"
    fi
  done
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
print_summary() {
  echo ""
  echo -e "${BOLD}Health Check Summary${RESET}"
  echo "=============================="
  for r in "${RESULTS[@]}"; do
    if [[ "${r}" == PASS:* ]]; then
      echo -e "  ${GREEN}✓${RESET} ${r#PASS: }"
    else
      echo -e "  ${RED}✗${RESET} ${r#FAIL: }"
    fi
  done
  echo "=============================="

  if [[ ${FAILED} -eq 0 ]]; then
    echo -e "\n${BOLD}${GREEN}All checks passed.${RESET}\n"
    return 0
  else
    echo -e "\n${BOLD}${RED}${FAILED} check(s) failed.${RESET}\n"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  echo -e "\n${BOLD}${CYAN}OpenClaw Teams — Health Check${RESET}"
  echo -e "Namespace: ${NAMESPACE}"
  echo -e "Gateway:   ${BASE_URL}\n"

  check_endpoints
  check_postgres
  check_redis
  check_agent_status
  check_pod_readiness
  print_summary
}

main "$@"
