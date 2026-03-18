#!/usr/bin/env bash
# teardown.sh — Tear down the entire benchmark platform
#
# Steps:
#   1. Stop and remove OMB Docker containers (docker-compose down)
#   2. Delete the K3D cluster
#   3. Optionally clean up certs/ and results/ directories
#
# Usage:
#   ./scripts/teardown.sh [--clean-certs] [--clean-results] [--all]

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${REPO_ROOT}/docker"
CLUSTER_NAME="confluent-benchmark"
CLEAN_CERTS=false
CLEAN_RESULTS=false

# Parse flags
for arg in "$@"; do
  case "${arg}" in
    --clean-certs)   CLEAN_CERTS=true  ;;
    --clean-results) CLEAN_RESULTS=true ;;
    --all)           CLEAN_CERTS=true; CLEAN_RESULTS=true ;;
    --help|-h)
      cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Tear down the OMB Confluent mTLS benchmark platform.

Options:
  --clean-certs    Also remove the certs/ directory
  --clean-results  Also remove the results/ directory
  --all            Equivalent to --clean-certs --clean-results
  --help           Show this help message

EOF
      exit 0
      ;;
    *) echo "[WARN] Unknown argument: ${arg}" ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Docker compose command
# ---------------------------------------------------------------------------
if command -v docker-compose &>/dev/null; then
  DC="docker-compose"
else
  DC="docker compose"
fi

# ---------------------------------------------------------------------------
# 1. Stop OMB Docker containers
# ---------------------------------------------------------------------------
info "Stopping OMB Docker containers..."
if [[ -f "${DOCKER_DIR}/docker-compose.yml" ]]; then
  DC_CMD="${DC} -f ${DOCKER_DIR}/docker-compose.yml"
  [[ -f "${REPO_ROOT}/.env" ]] && DC_CMD="${DC_CMD} --env-file ${REPO_ROOT}/.env"
  ${DC_CMD} down --remove-orphans --volumes 2>/dev/null || \
    warn "docker-compose down failed or containers were not running"
else
  warn "docker-compose.yml not found — skipping container teardown"
fi

# ---------------------------------------------------------------------------
# 2. Delete K3D cluster
# ---------------------------------------------------------------------------
if command -v k3d &>/dev/null; then
  if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME}"; then
    info "Deleting K3D cluster '${CLUSTER_NAME}'..."
    k3d cluster delete "${CLUSTER_NAME}"
    info "  Cluster deleted."
  else
    info "K3D cluster '${CLUSTER_NAME}' does not exist — nothing to delete."
  fi
else
  warn "k3d not found — skipping cluster deletion"
fi

# ---------------------------------------------------------------------------
# 3. Clean up certs/ directory
# ---------------------------------------------------------------------------
if [[ "${CLEAN_CERTS}" == "true" ]]; then
  if [[ -d "${REPO_ROOT}/certs" ]]; then
    info "Removing certs/ directory..."
    rm -rf "${REPO_ROOT}/certs"
    info "  certs/ removed."
  else
    info "certs/ directory does not exist — nothing to remove."
  fi
fi

# ---------------------------------------------------------------------------
# 4. Clean up results/ directory
# ---------------------------------------------------------------------------
if [[ "${CLEAN_RESULTS}" == "true" ]]; then
  if [[ -d "${REPO_ROOT}/results" ]]; then
    info "Removing results/ directory..."
    rm -rf "${REPO_ROOT}/results"
    info "  results/ removed."
  else
    info "results/ directory does not exist — nothing to remove."
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat <<EOF

[INFO]  ============================================================
[INFO]  Teardown complete.
[INFO]
[INFO]  Removed:
[INFO]    - OMB Docker containers (omb-worker-1/2/3, omb-driver)
[INFO]    - K3D cluster '${CLUSTER_NAME}'
$(  [[ "${CLEAN_CERTS}"   == "true" ]] && echo "[INFO]    - certs/ directory" || echo "[INFO]    - certs/ directory  (preserved — use --clean-certs to remove)" )
$(  [[ "${CLEAN_RESULTS}" == "true" ]] && echo "[INFO]    - results/ directory" || echo "[INFO]    - results/ directory (preserved — use --clean-results to remove)" )
[INFO]  ============================================================

EOF
