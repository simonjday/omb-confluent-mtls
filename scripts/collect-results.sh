#!/usr/bin/env bash
# collect-results.sh — Collect and summarize OMB benchmark results
#
# Reads a JSON results file produced by the OMB driver and prints
# a human-readable summary of key metrics.
#
# Usage:
#   ./scripts/collect-results.sh [results-file]
#
# If no results-file is given, uses the most recent file in results/.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESULTS_DIR="${REPO_ROOT}/results"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [results-file]

If no results-file is provided, the most recent file in results/ is used.

The results file is a JSON file produced by the OMB driver.

EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage; exit 0
fi

# ---------------------------------------------------------------------------
# Find results file
# ---------------------------------------------------------------------------
RESULTS_FILE="${1:-}"

if [[ -z "${RESULTS_FILE}" ]]; then
  # Use most recent file in results/
  RESULTS_FILE=$(ls -t "${RESULTS_DIR}"/*.json 2>/dev/null | head -1 || true)
  if [[ -z "${RESULTS_FILE}" ]]; then
    error "No results files found in ${RESULTS_DIR}. Run a benchmark first."
  fi
  info "Using most recent results file: ${RESULTS_FILE}"
fi

[[ -f "${RESULTS_FILE}" ]] || error "Results file not found: ${RESULTS_FILE}"

# ---------------------------------------------------------------------------
# Check for jq
# ---------------------------------------------------------------------------
if command -v jq &>/dev/null; then
  USE_JQ=true
else
  USE_JQ=false
  info "jq not found — printing raw JSON (install jq for formatted output)"
fi

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
cat <<EOF

==================================================================
  OMB Benchmark Results Summary
==================================================================
  File: ${RESULTS_FILE}
==================================================================

EOF

if [[ "${USE_JQ}" == "true" ]]; then
  # Extract key metrics from OMB JSON result format
  jq -r '
    "Workload:            " + (.workload // "unknown"),
    "Topics:              " + ((.topics // 0) | tostring),
    "Partitions/Topic:    " + ((.partitionsPerTopic // 0) | tostring),
    "Producers:           " + ((.producersPerTopic // 0) | tostring),
    "Consumers:           " + ((.consumersPerSubscription // 0) | tostring),
    "Message Size (B):    " + ((.messageSize // 0) | tostring),
    "",
    "--- Publish ---",
    "Throughput (msg/s):  " + ((.publishRate // 0) | tostring),
    "Throughput (MB/s):   " + ((.publishThroughput // 0) | tostring),
    "Latency p50 (ms):    " + ((.aggregatedPublishLatency50pct // 0) | tostring),
    "Latency p75 (ms):    " + ((.aggregatedPublishLatency75pct // 0) | tostring),
    "Latency p95 (ms):    " + ((.aggregatedPublishLatency95pct // 0) | tostring),
    "Latency p99 (ms):    " + ((.aggregatedPublishLatency99pct // 0) | tostring),
    "Latency p999 (ms):   " + ((.aggregatedPublishLatency999pct // 0) | tostring),
    "Latency Max (ms):    " + ((.aggregatedPublishLatencyMax // 0) | tostring),
    "",
    "--- End-to-End ---",
    "Latency p50 (ms):    " + ((.aggregatedEndToEndLatency50pct // 0) | tostring),
    "Latency p75 (ms):    " + ((.aggregatedEndToEndLatency75pct // 0) | tostring),
    "Latency p95 (ms):    " + ((.aggregatedEndToEndLatency95pct // 0) | tostring),
    "Latency p99 (ms):    " + ((.aggregatedEndToEndLatency99pct // 0) | tostring),
    "Latency p999 (ms):   " + ((.aggregatedEndToEndLatency999pct // 0) | tostring),
    "Latency Max (ms):    " + ((.aggregatedEndToEndLatencyMax // 0) | tostring)
  ' "${RESULTS_FILE}" 2>/dev/null || \
    echo "(Could not parse expected JSON fields — printing raw content below)"

  echo ""
  echo "--- Raw JSON ---"
  jq '.' "${RESULTS_FILE}"
else
  cat "${RESULTS_FILE}"
fi

cat <<EOF

==================================================================
  Results file: ${RESULTS_FILE}
==================================================================

EOF
