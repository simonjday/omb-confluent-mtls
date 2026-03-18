#!/usr/bin/env bash
# setup-all.sh — Full end-to-end platform setup orchestration
#
# Steps:
#   1. Check prerequisites
#   2. Create K3D cluster and install CFK operator
#   3. Generate mTLS certificates
#   4. Create Kubernetes secrets
#   5. Apply namespace and Confluent Platform manifests (KRaft)
#   6. Wait for KraftController and Kafka pods to be ready
#   7. Build OMB Docker images
#   8. Print summary
#
# Usage:
#   ./scripts/setup-all.sh [--skip-cluster] [--skip-certs] [--skip-images]

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="confluent"

SKIP_CLUSTER="${SKIP_CLUSTER:-false}"
SKIP_CERTS="${SKIP_CERTS:-false}"
SKIP_IMAGES="${SKIP_IMAGES:-false}"

# Parse flags
for arg in "$@"; do
  case "${arg}" in
    --skip-cluster) SKIP_CLUSTER=true ;;
    --skip-certs)   SKIP_CERTS=true   ;;
    --skip-images)  SKIP_IMAGES=true  ;;
    --help|-h)
      cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --skip-cluster   Skip K3D cluster creation (use existing cluster)
  --skip-certs     Skip certificate generation (use existing certs)
  --skip-images    Skip OMB Docker image build
  --help           Show this help message

Environment variables:
  KEYSTORE_PASSWORD    JKS keystore password   (default: changeit)
  TRUSTSTORE_PASSWORD  JKS truststore password (default: changeit)

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
error() { echo "[ERROR] $*" >&2; exit 1; }

step() {
  echo ""
  echo "=================================================================="
  echo "  STEP: $*"
  echo "=================================================================="
}

# ---------------------------------------------------------------------------
# 1. Check prerequisites
# ---------------------------------------------------------------------------
step "Checking prerequisites"
REQUIRED_TOOLS=(docker k3d kubectl helm openssl keytool)
MISSING=()

for cmd in "${REQUIRED_TOOLS[@]}"; do
  if command -v "${cmd}" &>/dev/null; then
    info "  [OK] ${cmd} — $(${cmd} --version 2>&1 | head -1 || true)"
  else
    MISSING+=("${cmd}")
    info "  [MISSING] ${cmd}"
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  error "Missing required tools: ${MISSING[*]}"
fi

# ---------------------------------------------------------------------------
# 2. Create K3D cluster + CFK operator
# ---------------------------------------------------------------------------
if [[ "${SKIP_CLUSTER}" == "false" ]]; then
  step "Creating K3D cluster and installing CFK operator"
  bash "${REPO_ROOT}/k3d/setup-k3d.sh"
else
  info "Skipping cluster creation (--skip-cluster)"
fi

# ---------------------------------------------------------------------------
# 3. Generate mTLS certificates
# ---------------------------------------------------------------------------
if [[ "${SKIP_CERTS}" == "false" ]]; then
  step "Generating mTLS certificates"
  bash "${REPO_ROOT}/confluent/mtls/generate-certs.sh"
else
  info "Skipping certificate generation (--skip-certs)"
fi

# ---------------------------------------------------------------------------
# 4. Create Kubernetes secrets
# ---------------------------------------------------------------------------
step "Creating Kubernetes secrets"
bash "${REPO_ROOT}/confluent/mtls/create-k8s-secrets.sh"

# ---------------------------------------------------------------------------
# 5. Apply namespace and Confluent Platform manifests
# ---------------------------------------------------------------------------
step "Applying Confluent Platform manifests (KRaft — no ZooKeeper)"
kubectl apply -f "${REPO_ROOT}/confluent/namespace.yaml"
kubectl apply -f "${REPO_ROOT}/confluent/confluent-platform.yaml"

# ---------------------------------------------------------------------------
# 6. Wait for KraftController and Kafka pods to be ready
# ---------------------------------------------------------------------------
step "Waiting for KraftController pods (3/3 ready)"
kubectl rollout status statefulset/kraftcontroller \
  -n "${NAMESPACE}" \
  --timeout=600s

step "Waiting for Kafka broker pods (3/3 ready)"
kubectl rollout status statefulset/kafka \
  -n "${NAMESPACE}" \
  --timeout=600s

info "All Confluent Platform pods are ready."
kubectl get pods -n "${NAMESPACE}"

# ---------------------------------------------------------------------------
# 7. Build OMB Docker images
# ---------------------------------------------------------------------------
if [[ "${SKIP_IMAGES}" == "false" ]]; then
  step "Building OMB Docker images"
  bash "${SCRIPT_DIR}/build-omb-images.sh"
else
  info "Skipping image build (--skip-images)"
fi

# ---------------------------------------------------------------------------
# 8. Summary
# ---------------------------------------------------------------------------
cat <<EOF

==================================================================
  SETUP COMPLETE
==================================================================

  K3D cluster:  confluent-benchmark
  Namespace:    ${NAMESPACE}
  KRaft mode:   YES (no ZooKeeper)

  Kafka bootstrap servers (host ports):
    localhost:9093  (kafka-0)
    localhost:9094  (kafka-1)
    localhost:9095  (kafka-2)

  Certificates:
    ${REPO_ROOT}/certs/

  OMB images:
    omb-worker:latest
    omb-driver:latest

  Run a benchmark:
    ./scripts/run-benchmark.sh [workload-name]

  Available workloads:
    simple-workload (default)
    high-throughput
    low-latency
    endurance

  Teardown:
    ./scripts/teardown.sh

==================================================================

EOF
