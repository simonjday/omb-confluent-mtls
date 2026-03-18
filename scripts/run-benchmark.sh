#!/usr/bin/env bash
# run-benchmark.sh — Start OMB workers and execute a benchmark workload
#
# Steps:
#   1. Validate prerequisites and workload file
#   2. Start OMB workers via docker-compose
#   3. Wait for all workers to report healthy
#   4. Run the benchmark driver with the specified workload
#   5. Collect and display results summary
#
# Usage:
#   ./scripts/run-benchmark.sh [workload-name]
#
# Arguments:
#   workload-name   Name of the workload file in omb/workloads/ (without .yaml)
#                   Default: simple-workload
#
# Examples:
#   ./scripts/run-benchmark.sh
#   ./scripts/run-benchmark.sh high-throughput
#   ./scripts/run-benchmark.sh low-latency

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${REPO_ROOT}/docker"
OMB_DIR="${REPO_ROOT}/omb"
RESULTS_DIR="${REPO_ROOT}/results"
WORKLOAD="${1:-simple-workload}"
WORKLOAD_FILE="${OMB_DIR}/workloads/${WORKLOAD}.yaml"
WORKER_PORTS=(8080 8081 8082)
WORKER_TIMEOUT=120

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [workload-name]

Available workloads:
$(ls "${OMB_DIR}/workloads/"*.yaml 2>/dev/null | xargs -I{} basename {} .yaml | sed 's/^/  /')

EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage; exit 0
fi

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
info "Validating prerequisites..."

command -v docker     &>/dev/null || error "docker not found"
command -v docker-compose 2>/dev/null || \
  docker compose version &>/dev/null   || error "docker compose not found"

[[ -f "${WORKLOAD_FILE}" ]] || error "Workload file not found: ${WORKLOAD_FILE}"
[[ -d "${REPO_ROOT}/certs" ]] || error "certs/ directory not found. Run: ./confluent/mtls/generate-certs.sh"

# Create results directory
mkdir -p "${RESULTS_DIR}"

# ---------------------------------------------------------------------------
# Docker compose command (supports both 'docker-compose' and 'docker compose')
# ---------------------------------------------------------------------------
if command -v docker-compose &>/dev/null; then
  DC="docker-compose"
else
  DC="docker compose"
fi

DC_CMD="${DC} -f ${DOCKER_DIR}/docker-compose.yml --env-file ${REPO_ROOT}/.env"
# If .env doesn't exist, don't fail — docker-compose will use defaults
[[ -f "${REPO_ROOT}/.env" ]] || DC_CMD="${DC} -f ${DOCKER_DIR}/docker-compose.yml"

# ---------------------------------------------------------------------------
# Start workers
# ---------------------------------------------------------------------------
info "Starting OMB workers..."
${DC_CMD} up -d omb-worker-1 omb-worker-2 omb-worker-3

# ---------------------------------------------------------------------------
# Wait for workers to be healthy
# ---------------------------------------------------------------------------
info "Waiting for workers to be healthy (timeout: ${WORKER_TIMEOUT}s)..."
DEADLINE=$(( $(date +%s) + WORKER_TIMEOUT ))

for port in "${WORKER_PORTS[@]}"; do
  info "  Waiting for worker on port ${port}..."
  until curl -sf "http://localhost:${port}/ping" &>/dev/null; do
    if [[ $(date +%s) -gt ${DEADLINE} ]]; then
      error "Timed out waiting for OMB worker on port ${port}"
    fi
    sleep 3
  done
  info "  Worker on port ${port} is healthy."
done

# ---------------------------------------------------------------------------
# Run benchmark
# ---------------------------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_FILE="${RESULTS_DIR}/${WORKLOAD}_${TIMESTAMP}.json"

info "Running benchmark: ${WORKLOAD}"
info "  Workload file: ${WORKLOAD_FILE}"
info "  Results will be written to: ${RESULT_FILE}"

${DC_CMD} run --rm \
  -v "${RESULTS_DIR}:/results" \
  omb-driver \
  bin/benchmark \
    --drivers /workloads/driver-kafka.yaml \
    --workers /workloads/workers.yaml \
    --output /results/"$(basename "${RESULT_FILE}")" \
    /workloads/workloads/"${WORKLOAD}.yaml"

# ---------------------------------------------------------------------------
# Show results summary
# ---------------------------------------------------------------------------
bash "${SCRIPT_DIR}/collect-results.sh" "${RESULT_FILE}"
