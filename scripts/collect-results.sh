#!/usr/bin/env bash
# collect-results.sh — Summarise OMB benchmark result JSON files
#
# Delegates to review-results.py for the actual analysis.
#
# Usage:
#   ./scripts/collect-results.sh                    # all files in results/
#   ./scripts/collect-results.sh results/foo.json   # specific file(s)
#   ./scripts/collect-results.sh --compare          # side-by-side comparison table

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "${SCRIPT_DIR}/review-results.py" "$@"
