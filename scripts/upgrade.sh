#!/usr/bin/env bash
# =============================================================================
# upgrade.sh — Zero-downtime rolling upgrade for openclaw-cwdev
# Usage: [IMAGE_TAG=v1.2.3] ./upgrade.sh
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

die() { log_error "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REGISTRY="${REGISTRY:-ghcr.io/clawworld}"
IMAGE_NAME="${IMAGE_NAME:-openclaw-cwdev}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

NAMESPACE="${NAMESPACE:-openclaw-production}"
DEPLOYMENT="${DEPLOYMENT:-openclaw-gateway}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
HEALTH_RETRIES="${HEALTH_RETRIES:-20}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-10}"

# -----------------------------------------------------------------------------
# Step 1 — Pull latest image
# -----------------------------------------------------------------------------
pull_image() {
  log_step "Pulling image: ${FULL_IMAGE}"

  if docker pull "${FULL_IMAGE}"; then
    log_success "Image pulled: ${FULL_IMAGE}"
  else
    die "Failed to pull image: ${FULL_IMAGE}"
  fi
}

# -----------------------------------------------------------------------------
# Step 2 — Record current state for rollback reference
# -----------------------------------------------------------------------------
record_pre_upgrade_state() {
  log_step "Recording pre-upgrade state"

  PREV_IMAGE=$(kubectl get deployment "${DEPLOYMENT}" \
    --namespace="${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")

  PREV_REVISION=$(kubectl get deployment "${DEPLOYMENT}" \
    --namespace="${NAMESPACE}" \
    -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null || echo "0")

  log_info "Previous image    : ${PREV_IMAGE}"
  log_info "Previous revision : ${PREV_REVISION}"
}

# -----------------------------------------------------------------------------
# Step 3 — Perform rolling update
# -----------------------------------------------------------------------------
rolling_update() {
  log_step "Performing rolling update → ${FULL_IMAGE}"

  kubectl set image deployment/"${DEPLOYMENT}" \
    "${DEPLOYMENT}=${FULL_IMAGE}" \
    --namespace="${NAMESPACE}" \
    --record 2>/dev/null || \
  kubectl set image deployment/"${DEPLOYMENT}" \
    "${DEPLOYMENT}=${FULL_IMAGE}" \
    --namespace="${NAMESPACE}"

  log_success "Image updated in deployment spec"
}

# -----------------------------------------------------------------------------
# Step 4 — Health gate — watch rollout and verify health
# -----------------------------------------------------------------------------
health_gate() {
  log_step "Health gate — watching rollout"

  # Watch rollout
  if ! kubectl rollout status deployment/"${DEPLOYMENT}" \
      --namespace="${NAMESPACE}" \
      --timeout="${ROLLOUT_TIMEOUT}"; then
    log_error "Rollout failed — initiating automatic rollback"
    kubectl rollout undo deployment/"${DEPLOYMENT}" --namespace="${NAMESPACE}" || true
    die "Rolling update aborted and rolled back"
  fi

  log_success "Rollout complete — running health gate"

  # Port-forward for health check
  kubectl port-forward \
    --namespace="${NAMESPACE}" \
    service/openclaw-gateway 18081:3000 &>/dev/null &
  PF_PID=$!
  trap 'kill ${PF_PID} 2>/dev/null || true' RETURN
  sleep 3

  local attempts=0
  while [[ ${attempts} -lt ${HEALTH_RETRIES} ]]; do
    if curl -sf --max-time 5 "http://localhost:18081/health" &>/dev/null; then
      log_success "Health gate passed after $((attempts + 1)) attempt(s)"
      kill ${PF_PID} 2>/dev/null || true
      return 0
    fi
    attempts=$((attempts + 1))
    log_info "Health check attempt ${attempts}/${HEALTH_RETRIES} ..."
    sleep "${HEALTH_INTERVAL}"
  done

  kill ${PF_PID} 2>/dev/null || true
  log_error "Health gate failed — initiating automatic rollback"
  kubectl rollout undo deployment/"${DEPLOYMENT}" --namespace="${NAMESPACE}" || true
  die "Upgrade aborted: health gate failed after ${HEALTH_RETRIES} attempts"
}

# -----------------------------------------------------------------------------
# Step 5 — Post-upgrade verification
# -----------------------------------------------------------------------------
verify_upgrade() {
  log_step "Post-upgrade verification"

  local new_image
  new_image=$(kubectl get deployment "${DEPLOYMENT}" \
    --namespace="${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")

  local ready
  ready=$(kubectl get deployment "${DEPLOYMENT}" \
    --namespace="${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

  local desired
  desired=$(kubectl get deployment "${DEPLOYMENT}" \
    --namespace="${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

  log_success "New image     : ${new_image}"
  log_success "Ready replicas: ${ready}/${desired}"

  if [[ "${new_image}" != "${FULL_IMAGE}" ]]; then
    log_warn "Deployed image (${new_image}) does not match target (${FULL_IMAGE})"
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  echo -e "\n${BOLD}${GREEN}OpenClaw Teams — Zero-Downtime Upgrade${RESET}"
  echo -e "${CYAN}Target image : ${FULL_IMAGE}${RESET}"
  echo -e "${CYAN}Namespace    : ${NAMESPACE}${RESET}\n"

  pull_image
  record_pre_upgrade_state
  rolling_update
  health_gate
  verify_upgrade

  echo -e "\n${BOLD}${GREEN}Upgrade complete!${RESET}"
  echo -e "  Previous : ${PREV_IMAGE}"
  echo -e "  Current  : ${FULL_IMAGE}"
}

main "$@"
