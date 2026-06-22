#!/usr/bin/env bash
# suspend.sh — Suspend the benchmark platform (preserves all cluster state)
#
# Stops OMB Docker containers and suspends the K3D cluster without deleting
# anything. All Kubernetes resources, secrets, and PVs are preserved on disk.
# Resume with: ./scripts/resume.sh
#
# Usage:
#   ./scripts/suspend.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${REPO_ROOT}/docker"
CLUSTER_NAME="confluent-benchmark"
NAMESPACE="${NAMESPACE:-confluent}"

info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*" >&2; }

if command -v docker-compose &>/dev/null; then DC="docker-compose"; else DC="docker compose"; fi

# ---------------------------------------------------------------------------
# 1. Kill any active port-forwards
# ---------------------------------------------------------------------------
info "Stopping port-forwards..."
pkill -f "port-forward svc/schemaregistry"         2>/dev/null || true
pkill -f "port-forward svc/controlcenter-next-gen" 2>/dev/null || true
success "Port-forwards stopped."

# ---------------------------------------------------------------------------
# 2. Stop OMB Docker containers
# ---------------------------------------------------------------------------
info "Stopping OMB Docker containers..."
DC_CMD="${DC} -f ${DOCKER_DIR}/docker-compose.yml"
[[ -f "${REPO_ROOT}/.env" ]] && DC_CMD="${DC_CMD} --env-file ${REPO_ROOT}/.env"
${DC_CMD} down --remove-orphans 2>/dev/null || true
success "OMB containers stopped."

# ---------------------------------------------------------------------------
# 3. Suspend the K3D cluster
# ---------------------------------------------------------------------------
if ! command -v k3d &>/dev/null; then
  warn "k3d not found — skipping cluster suspend"
  exit 0
fi

if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME}"; then
  info "Suspending K3D cluster '${CLUSTER_NAME}'..."
  k3d cluster stop "${CLUSTER_NAME}"
  success "Cluster '${CLUSTER_NAME}' suspended."
else
  warn "Cluster '${CLUSTER_NAME}' not found — nothing to suspend."
fi

cat <<EOF

[INFO]  ============================================================
[INFO]  Platform suspended. All cluster state preserved.
[INFO]
[INFO]  Resume with:
[INFO]    ./scripts/resume.sh
[INFO]  ============================================================

EOF
