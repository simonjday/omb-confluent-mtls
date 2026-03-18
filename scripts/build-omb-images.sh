#!/usr/bin/env bash
# build-omb-images.sh — Build OMB worker and driver Docker images
#
# Builds:
#   omb-worker:latest   — OMB worker process (accepts benchmark tasks)
#   omb-driver:latest   — OMB driver (orchestrates workers, runs workloads)
#
# Tags each image with both 'latest' and a timestamp-based version tag.
#
# Usage:
#   ./scripts/build-omb-images.sh [--no-cache]

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${REPO_ROOT}/docker"
VERSION="$(date +%Y%m%d%H%M%S)"
NO_CACHE="${1:-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [--no-cache]

Builds omb-worker and omb-driver Docker images from docker/.

Options:
  --no-cache   Pass --no-cache to docker build

EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage; exit 0
fi

command -v docker &>/dev/null || error "docker not found in PATH"

BUILD_ARGS=""
if [[ "${NO_CACHE}" == "--no-cache" ]]; then
  BUILD_ARGS="--no-cache"
fi

# ---------------------------------------------------------------------------
# Build OMB worker image
# ---------------------------------------------------------------------------
info "Building omb-worker image (version: ${VERSION})..."
docker build \
  ${BUILD_ARGS} \
  -f "${DOCKER_DIR}/Dockerfile.omb-worker" \
  -t "omb-worker:${VERSION}" \
  -t "omb-worker:latest" \
  "${DOCKER_DIR}"

info "  Tagged: omb-worker:${VERSION}"
info "  Tagged: omb-worker:latest"

# ---------------------------------------------------------------------------
# Build OMB driver image
# ---------------------------------------------------------------------------
info "Building omb-driver image (version: ${VERSION})..."
docker build \
  ${BUILD_ARGS} \
  -f "${DOCKER_DIR}/Dockerfile.omb-driver" \
  -t "omb-driver:${VERSION}" \
  -t "omb-driver:latest" \
  "${DOCKER_DIR}"

info "  Tagged: omb-driver:${VERSION}"
info "  Tagged: omb-driver:latest"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat <<EOF

[INFO]  ============================================================
[INFO]  OMB Docker images built successfully.
[INFO]
[INFO]  Images:
[INFO]    omb-worker:latest  ($(docker image inspect omb-worker:latest --format '{{.Size}}' | numfmt --to=iec))
[INFO]    omb-driver:latest  ($(docker image inspect omb-driver:latest --format '{{.Size}}' | numfmt --to=iec))
[INFO]
[INFO]  Run a benchmark:
[INFO]    ./scripts/run-benchmark.sh [workload-name]
[INFO]  ============================================================

EOF
