#!/usr/bin/env bash
# =============================================================================
# rollback.sh — Emergency rollback for openclaw-teams
# Usage: [REVISION=<n>] [SLACK_WEBHOOK=<url>] ./rollback.sh
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

die() { log_error "$*"; notify_slack "FAILED" "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-openclaw-production}"
DEPLOYMENT="${DEPLOYMENT:-openclaw-gateway}"
REVISION="${REVISION:-}"           # empty = undo to previous revision
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

# -----------------------------------------------------------------------------
# Slack notification
# -----------------------------------------------------------------------------
notify_slack() {
  local status="$1"
  local message="${2:-}"

  if [[ -z "${SLACK_WEBHOOK}" ]]; then
    log_warn "SLACK_WEBHOOK not set — skipping notification"
    return 0
  fi

  local color="good"
  local emoji=":white_check_mark:"
  if [[ "${status}" != "SUCCESS" ]]; then
    color="danger"
    emoji=":rotating_light:"
  fi

  local current_image
  current_image=$(kubectl get deployment "${DEPLOYMENT}" \
    --namespace="${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")

  local payload
  payload=$(cat <<EOF
{
  "attachments": [
    {
      "color": "${color}",
      "title": "${emoji} openclaw-teams Rollback — ${status}",
      "fields": [
        { "title": "Namespace",   "value": "${NAMESPACE}",     "short": true },
        { "title": "Deployment",  "value": "${DEPLOYMENT}",    "short": true },
        { "title": "Current Image", "value": "${current_image}", "short": false },
        { "title": "Message",     "value": "${message}",       "short": false }
      ],
      "footer": "openclaw-teams deploy system",
      "ts": $(date +%s)
    }
  ]
}
EOF
)

  if curl -sf -X POST \
      -H "Content-Type: application/json" \
      --data "${payload}" \
      "${SLACK_WEBHOOK}" &>/dev/null; then
    log_info "Slack notification sent (${status})"
  else
    log_warn "Failed to send Slack notification"
  fi
}

# -----------------------------------------------------------------------------
# Step 1 — Show current state
# -----------------------------------------------------------------------------
show_current_state() {
  log_step "Current deployment state"

  log_info "Rollout history for ${DEPLOYMENT}:"
  kubectl rollout history deployment/"${DEPLOYMENT}" --namespace="${NAMESPACE}" || true

  local current_image
  current_image=$(kubectl get deployment "${DEPLOYMENT}" \
    --namespace="${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")
  log_info "Current image: ${current_image}"
}

# -----------------------------------------------------------------------------
# Step 2 — Execute rollback
# -----------------------------------------------------------------------------
do_rollback() {
  log_step "Executing rollback"

  if [[ -n "${REVISION}" ]]; then
    log_info "Rolling back to revision ${REVISION}"
    kubectl rollout undo deployment/"${DEPLOYMENT}" \
      --namespace="${NAMESPACE}" \
      --to-revision="${REVISION}"
  else
    log_info "Rolling back to previous revision"
    kubectl rollout undo deployment/"${DEPLOYMENT}" \
      --namespace="${NAMESPACE}"
  fi
}

# -----------------------------------------------------------------------------
# Step 3 — Wait for rollback rollout
# -----------------------------------------------------------------------------
wait_for_rollback() {
  log_step "Waiting for rollback to complete (timeout: ${ROLLOUT_TIMEOUT})"

  if kubectl rollout status deployment/"${DEPLOYMENT}" \
      --namespace="${NAMESPACE}" \
      --timeout="${ROLLOUT_TIMEOUT}"; then
    log_success "Rollback rollout complete"
  else
    die "Rollback rollout timed out or failed"
  fi
}

# -----------------------------------------------------------------------------
# Step 4 — Verify rollback
# -----------------------------------------------------------------------------
verify_rollback() {
  log_step "Verifying rollback"

  local ready
  ready=$(kubectl get deployment "${DEPLOYMENT}" \
    --namespace="${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  local desired
  desired=$(kubectl get deployment "${DEPLOYMENT}" \
    --namespace="${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

  if [[ "${ready}" == "${desired}" ]] && [[ "${ready}" != "0" ]]; then
    local new_image
    new_image=$(kubectl get deployment "${DEPLOYMENT}" \
      --namespace="${NAMESPACE}" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")
    log_success "Rollback verified: ${ready}/${desired} replicas ready"
    log_success "Active image: ${new_image}"
    return 0
  else
    die "Rollback verification failed: only ${ready:-0}/${desired} replicas ready"
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  echo -e "\n${BOLD}${RED}OpenClaw Teams — Emergency Rollback${RESET}"
  echo -e "${CYAN}Namespace  : ${NAMESPACE}${RESET}"
  echo -e "${CYAN}Deployment : ${DEPLOYMENT}${RESET}"
  if [[ -n "${REVISION}" ]]; then
    echo -e "${CYAN}Target Rev : ${REVISION}${RESET}"
  else
    echo -e "${CYAN}Target Rev : previous${RESET}"
  fi
  echo ""

  # Confirm unless CI
  if [[ "${CI:-false}" != "true" ]]; then
    read -rp "$(echo -e "${YELLOW}Proceed with rollback? [y/N]:${RESET} ")" confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || { log_info "Rollback cancelled"; exit 0; }
  fi

  show_current_state
  do_rollback
  wait_for_rollback
  verify_rollback

  local success_msg="Rollback completed successfully"
  echo -e "\n${BOLD}${GREEN}${success_msg}${RESET}"
  notify_slack "SUCCESS" "${success_msg}"
}

main "$@"
