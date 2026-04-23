#!/usr/bin/env bash
# =============================================================================
# cleanup.sh — Clean up old Docker images, K8s pods, logs, and vacuum Postgres
# Usage: [DRY_RUN=true] [LOG_DIR=/path] ./cleanup.sh
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

log_info()    { echo -e "${BLUE}[INFO]${RESET}  $(date '+%H:%M:%S') $*"; }
log_success() { echo -e "${GREEN}[OK]${RESET}    $(date '+%H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $(date '+%H:%M:%S') $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $(date '+%H:%M:%S') $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}==> $*${RESET}"; }

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
DRY_RUN="${DRY_RUN:-false}"
NAMESPACE="${NAMESPACE:-openclaw-production}"
REGISTRY="${REGISTRY:-ghcr.io/clawworld}"
IMAGE_NAME="${IMAGE_NAME:-openclaw-teams}"
LOG_DIR="${LOG_DIR:-/app/logs}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
POSTGRES_DB="${POSTGRES_DB:-openclaw_teams}"
POSTGRES_USER="${POSTGRES_USER:-openclaw}"

FREED_SPACE=0
CLEANED_ITEMS=0

run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "[DRY RUN] Would run: $*"
  else
    "$@"
  fi
}

# -----------------------------------------------------------------------------
# Step 1 — Remove old Docker images
# -----------------------------------------------------------------------------
cleanup_docker_images() {
  log_step "Cleaning up old Docker images"

  if ! command -v docker &>/dev/null; then
    log_warn "docker not found — skipping image cleanup"
    return
  fi

  # Remove dangling images (untagged)
  local dangling
  dangling=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${dangling}" -gt 0 ]]; then
    log_info "Removing ${dangling} dangling images"
    if [[ "${DRY_RUN}" != "true" ]]; then
      docker images -f "dangling=true" -q | xargs --no-run-if-empty docker rmi -f
    fi
    CLEANED_ITEMS=$((CLEANED_ITEMS + dangling))
  else
    log_info "No dangling images found"
  fi

  # Remove old tagged images for this repo (keep last 5)
  local old_images
  old_images=$(docker images "${REGISTRY}/${IMAGE_NAME}" \
    --format "{{.ID}}" 2>/dev/null | tail -n +6 || true)

  if [[ -n "${old_images}" ]]; then
    local count
    count=$(echo "${old_images}" | wc -l | tr -d ' ')
    log_info "Removing ${count} old ${IMAGE_NAME} image(s)"
    if [[ "${DRY_RUN}" != "true" ]]; then
      echo "${old_images}" | xargs --no-run-if-empty docker rmi -f 2>/dev/null || true
    fi
    CLEANED_ITEMS=$((CLEANED_ITEMS + count))
  else
    log_info "No old tagged images to remove"
  fi

  # Docker system prune (build cache older than 48h)
  log_info "Pruning Docker build cache older than 48h"
  run docker builder prune --filter "until=48h" -f 2>/dev/null || true

  log_success "Docker image cleanup done"
}

# -----------------------------------------------------------------------------
# Step 2 — Delete completed/failed pods
# -----------------------------------------------------------------------------
cleanup_pods() {
  log_step "Cleaning up completed/failed Kubernetes pods"

  if ! command -v kubectl &>/dev/null; then
    log_warn "kubectl not found — skipping pod cleanup"
    return
  fi

  # Completed pods
  local completed
  completed=$(kubectl get pods \
    --namespace="${NAMESPACE}" \
    --field-selector=status.phase==Succeeded \
    -o name 2>/dev/null | wc -l | tr -d ' ')

  if [[ "${completed}" -gt 0 ]]; then
    log_info "Deleting ${completed} Succeeded pod(s)"
    run kubectl delete pods \
      --namespace="${NAMESPACE}" \
      --field-selector=status.phase==Succeeded 2>/dev/null || true
    CLEANED_ITEMS=$((CLEANED_ITEMS + completed))
  else
    log_info "No Succeeded pods to delete"
  fi

  # Failed pods
  local failed
  failed=$(kubectl get pods \
    --namespace="${NAMESPACE}" \
    --field-selector=status.phase==Failed \
    -o name 2>/dev/null | wc -l | tr -d ' ')

  if [[ "${failed}" -gt 0 ]]; then
    log_info "Deleting ${failed} Failed pod(s)"
    run kubectl delete pods \
      --namespace="${NAMESPACE}" \
      --field-selector=status.phase==Failed 2>/dev/null || true
    CLEANED_ITEMS=$((CLEANED_ITEMS + failed))
  else
    log_info "No Failed pods to delete"
  fi

  log_success "Pod cleanup done"
}

# -----------------------------------------------------------------------------
# Step 3 — Clean up logs older than N days
# -----------------------------------------------------------------------------
cleanup_logs() {
  log_step "Cleaning up log files older than ${LOG_RETENTION_DAYS} days"

  if [[ ! -d "${LOG_DIR}" ]]; then
    log_warn "Log directory ${LOG_DIR} does not exist — skipping"
    return
  fi

  local old_logs
  old_logs=$(find "${LOG_DIR}" -type f -name "*.log" \
    -mtime "+${LOG_RETENTION_DAYS}" 2>/dev/null || true)

  if [[ -n "${old_logs}" ]]; then
    local count
    count=$(echo "${old_logs}" | wc -l | tr -d ' ')
    log_info "Found ${count} log file(s) older than ${LOG_RETENTION_DAYS} days"
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "${old_logs}" | while read -r f; do log_warn "[DRY RUN] Would delete: ${f}"; done
    else
      echo "${old_logs}" | xargs --no-run-if-empty rm -f
    fi
    CLEANED_ITEMS=$((CLEANED_ITEMS + count))
    log_success "Removed ${count} old log file(s)"
  else
    log_info "No old logs found"
  fi

  # Compress logs older than 7 days but younger than retention
  local compressible
  compressible=$(find "${LOG_DIR}" -type f -name "*.log" \
    -mtime "+7" -not -name "*.gz" 2>/dev/null || true)
  if [[ -n "${compressible}" ]]; then
    local ccount
    ccount=$(echo "${compressible}" | wc -l | tr -d ' ')
    log_info "Compressing ${ccount} log file(s)"
    if [[ "${DRY_RUN}" != "true" ]]; then
      echo "${compressible}" | xargs --no-run-if-empty gzip -9 2>/dev/null || true
    fi
  fi
}

# -----------------------------------------------------------------------------
# Step 4 — Vacuum PostgreSQL
# -----------------------------------------------------------------------------
vacuum_postgres() {
  log_step "Running PostgreSQL VACUUM ANALYZE"

  if ! kubectl get pod postgres-0 --namespace="${NAMESPACE}" &>/dev/null; then
    log_warn "postgres-0 pod not found — skipping vacuum"
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "[DRY RUN] Would run: VACUUM ANALYZE on ${POSTGRES_DB}"
    return
  fi

  log_info "Running VACUUM ANALYZE on ${POSTGRES_DB}..."
  if kubectl exec postgres-0 --namespace="${NAMESPACE}" -- \
      psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
      -c "VACUUM ANALYZE;" 2>/dev/null; then
    log_success "VACUUM ANALYZE complete"
  else
    log_warn "VACUUM ANALYZE failed (non-fatal)"
  fi

  # Show table bloat summary
  log_info "Top bloated tables:"
  kubectl exec postgres-0 --namespace="${NAMESPACE}" -- \
    psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -t \
    -c "SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size FROM pg_tables WHERE schemaname='public' ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC LIMIT 5;" \
    2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
print_summary() {
  echo ""
  echo -e "${BOLD}Cleanup Summary${RESET}"
  echo "============================="
  echo -e "  Items cleaned : ${CLEANED_ITEMS}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo -e "  Mode          : ${YELLOW}DRY RUN — no changes made${RESET}"
  fi
  echo "============================="
  log_success "Cleanup complete"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  echo -e "\n${BOLD}${CYAN}OpenClaw Teams — Cleanup${RESET}"
  echo -e "Namespace : ${NAMESPACE}"
  echo -e "Log dir   : ${LOG_DIR}"
  echo -e "Retention : ${LOG_RETENTION_DAYS} days\n"
  [[ "${DRY_RUN}" == "true" ]] && echo -e "${YELLOW}Mode: DRY RUN${RESET}\n"

  cleanup_docker_images
  cleanup_pods
  cleanup_logs
  vacuum_postgres
  print_summary
}

main "$@"
