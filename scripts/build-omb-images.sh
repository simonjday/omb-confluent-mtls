#!/usr/bin/env bash
# build-omb-images.sh — Build the unified OMB Docker image
#
# Builds:
#   omb:latest   — Single image that runs as either worker or driver
#                  Worker mode: docker run omb:latest (default CMD)
#                  Driver mode: docker run omb:latest bin/benchmark ...
#
# Tags the image with both 'latest' and a timestamp-based version tag.
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

Builds the unified omb Docker image from docker/Dockerfile.

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
# Build unified OMB image
# ---------------------------------------------------------------------------
info "Building omb image (version: ${VERSION})..."
docker build \
  ${BUILD_ARGS} \
  -f "${DOCKER_DIR}/Dockerfile" \
  -t "omb:${VERSION}" \
  -t "omb:latest" \
  "${DOCKER_DIR}"

info "  Tagged: omb:${VERSION}"
info "  Tagged: omb:latest"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat <<EOF

[INFO]  ============================================================
[INFO]  OMB Docker image built successfully.
[INFO]
[INFO]  Image:
[INFO]    omb:latest  ($(docker image inspect omb:latest --format '{{.Size}}' | numfmt --to=iec))
[INFO]
[INFO]  Worker mode (default):
[INFO]    docker run omb:latest
[INFO]
[INFO]  Driver mode:
[INFO]    docker run omb:latest bin/benchmark --drivers ... --workers ...
[INFO]
[INFO]  Run a benchmark:
[INFO]    ./scripts/run-benchmark.sh [workload-name]
[INFO]  ============================================================

EOF
