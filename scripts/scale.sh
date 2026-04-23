#!/usr/bin/env bash
# =============================================================================
# scale.sh — Scale openclaw-teams services
# Usage: ./scale.sh [up|down|auto] [replicas]
#   up    — scale to specified replicas (or current + 2)
#   down  — scale to specified replicas (or current - 1, min 1)
#   auto  — patch HPA back to defaults (min=2, max=10)
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
log_success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}==> $*${RESET}"; }

die() { log_error "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-openclaw-production}"
DEPLOYMENT="${DEPLOYMENT:-openclaw-gateway}"
HPA="${HPA:-openclaw-gateway}"
HPA_MIN="${HPA_MIN:-2}"
HPA_MAX="${HPA_MAX:-10}"

# -----------------------------------------------------------------------------
# Show current state
# -----------------------------------------------------------------------------
show_state() {
  log_step "Current state"

  echo ""
  echo -e "${BOLD}Deployment: ${DEPLOYMENT}${RESET}"
  kubectl get deployment "${DEPLOYMENT}" \
    --namespace="${NAMESPACE}" \
    -o wide 2>/dev/null || log_warn "Deployment not found"

  echo ""
  echo -e "${BOLD}HPA: ${HPA}${RESET}"
  kubectl get hpa "${HPA}" \
    --namespace="${NAMESPACE}" 2>/dev/null || log_warn "HPA not found"

  echo ""
  echo -e "${BOLD}Pods:${RESET}"
  kubectl get pods \
    --namespace="${NAMESPACE}" \
    -l "app.kubernetes.io/name=${DEPLOYMENT}" \
    -o wide 2>/dev/null || log_warn "No pods found"
}

# -----------------------------------------------------------------------------
# Get current replica count
# -----------------------------------------------------------------------------
get_current_replicas() {
  kubectl get deployment "${DEPLOYMENT}" \
    --namespace="${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1"
}

# -----------------------------------------------------------------------------
# Scale up
# -----------------------------------------------------------------------------
scale_up() {
  local target="${1:-}"
  local current
  current=$(get_current_replicas)

  if [[ -z "${target}" ]]; then
    target=$((current + 2))
  fi

  log_step "Scaling UP: ${current} → ${target} replicas"
  [[ "${target}" -gt "${HPA_MAX}" ]] && \
    log_warn "Target (${target}) exceeds HPA max (${HPA_MAX}) — patching HPA max"

  kubectl scale deployment "${DEPLOYMENT}" \
    --namespace="${NAMESPACE}" \
    --replicas="${target}"

  # Patch HPA min to match if target > current HPA min
  if [[ "${target}" -gt "${HPA_MIN}" ]]; then
    kubectl patch hpa "${HPA}" \
      --namespace="${NAMESPACE}" \
      --type=merge \
      --patch "{\"spec\":{\"minReplicas\":${target},\"maxReplicas\":$((target > HPA_MAX ? target : HPA_MAX))}}" \
      2>/dev/null || log_warn "Could not patch HPA"
  fi

  log_success "Scaled to ${target} replicas"
}

# -----------------------------------------------------------------------------
# Scale down
# -----------------------------------------------------------------------------
scale_down() {
  local target="${1:-}"
  local current
  current=$(get_current_replicas)

  if [[ -z "${target}" ]]; then
    target=$((current - 1))
    [[ "${target}" -lt 1 ]] && target=1
  fi

  [[ "${target}" -lt 1 ]] && die "Cannot scale below 1 replica"

  log_step "Scaling DOWN: ${current} → ${target} replicas"

  kubectl scale deployment "${DEPLOYMENT}" \
    --namespace="${NAMESPACE}" \
    --replicas="${target}"

  # Restore HPA min
  local new_min="${HPA_MIN}"
  [[ "${target}" -lt "${new_min}" ]] && new_min="${target}"
  kubectl patch hpa "${HPA}" \
    --namespace="${NAMESPACE}" \
    --type=merge \
    --patch "{\"spec\":{\"minReplicas\":${new_min}}}" \
    2>/dev/null || log_warn "Could not patch HPA"

  log_success "Scaled to ${target} replicas"
}

# -----------------------------------------------------------------------------
# Auto (restore HPA defaults)
# -----------------------------------------------------------------------------
scale_auto() {
  log_step "Restoring HPA autoscaling (min=${HPA_MIN}, max=${HPA_MAX})"

  kubectl patch hpa "${HPA}" \
    --namespace="${NAMESPACE}" \
    --type=merge \
    --patch "{\"spec\":{\"minReplicas\":${HPA_MIN},\"maxReplicas\":${HPA_MAX}}}"

  log_success "HPA restored to defaults — autoscaling is active"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  local action="${1:-}"
  local replicas="${2:-}"

  echo -e "\n${BOLD}${CYAN}OpenClaw Teams — Scale Service${RESET}"

  case "${action}" in
    up)
      scale_up "${replicas}"
      ;;
    down)
      scale_down "${replicas}"
      ;;
    auto)
      scale_auto
      ;;
    "")
      echo -e "${YELLOW}Usage: $0 [up|down|auto] [replicas]${RESET}"
      show_state
      exit 0
      ;;
    *)
      die "Unknown action '${action}'. Use: up | down | auto"
      ;;
  esac

  show_state
}

main "$@"
