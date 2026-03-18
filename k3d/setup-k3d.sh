#!/usr/bin/env bash
# setup-k3d.sh — Bootstrap a K3D cluster and install the CFK operator
#
# Steps:
#   1. Validate prerequisites
#   2. Create K3D cluster from k3d-cluster-config.yaml
#   3. Wait for all nodes to be ready
#   4. Add Confluent Helm repository
#   5. Install Confluent for Kubernetes (CFK) operator into the 'confluent' namespace
#
# Usage:
#   ./k3d/setup-k3d.sh [--dry-run]

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_CONFIG="${SCRIPT_DIR}/k3d-cluster-config.yaml"
CLUSTER_NAME="confluent-benchmark"
CONFLUENT_NAMESPACE="confluent"
HELM_REPO_NAME="confluentinc"
HELM_REPO_URL="https://packages.confluent.io/helm"
CFK_CHART="confluentinc/confluent-for-kubernetes"
CFK_VERSION="0.824.32"  # Pin to a known-good version; update as needed
DRY_RUN="${1:-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run]

  --dry-run   Print commands without executing them

EOF
}

run() {
  if [[ "${DRY_RUN}" == "--dry-run" ]]; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# 1. Validate prerequisites
# ---------------------------------------------------------------------------
check_prerequisites() {
  info "Checking prerequisites..."
  local missing=()

  for cmd in k3d kubectl helm; do
    if ! command -v "${cmd}" &>/dev/null; then
      missing+=("${cmd}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required tools: ${missing[*]}"
  fi

  info "All prerequisites satisfied."
  info "  k3d    : $(k3d version | head -1)"
  info "  kubectl: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
  info "  helm   : $(helm version --short)"
}

# ---------------------------------------------------------------------------
# 2. Create K3D cluster
# ---------------------------------------------------------------------------
create_cluster() {
  if k3d cluster list | grep -q "^${CLUSTER_NAME}"; then
    warn "Cluster '${CLUSTER_NAME}' already exists — skipping creation."
    return 0
  fi

  info "Creating K3D cluster '${CLUSTER_NAME}' from ${CLUSTER_CONFIG}..."
  run k3d cluster create --config "${CLUSTER_CONFIG}"
  info "Cluster created."
}

# ---------------------------------------------------------------------------
# 3. Wait for all nodes to be ready
# ---------------------------------------------------------------------------
wait_for_nodes() {
  info "Waiting for all nodes to be Ready..."
  run kubectl wait node --all --for=condition=Ready --timeout=300s
  info "All nodes are Ready:"
  kubectl get nodes -o wide
}

# ---------------------------------------------------------------------------
# 4. Add Confluent Helm repository
# ---------------------------------------------------------------------------
add_helm_repo() {
  if helm repo list 2>/dev/null | grep -q "^${HELM_REPO_NAME}"; then
    info "Helm repo '${HELM_REPO_NAME}' already added — updating..."
    run helm repo update "${HELM_REPO_NAME}"
  else
    info "Adding Confluent Helm repo..."
    run helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}"
    run helm repo update
  fi
}

# ---------------------------------------------------------------------------
# 5. Install CFK operator
# ---------------------------------------------------------------------------
install_cfk_operator() {
  info "Creating namespace '${CONFLUENT_NAMESPACE}' if not exists..."
  run kubectl create namespace "${CONFLUENT_NAMESPACE}" --dry-run=client -o yaml | \
    kubectl apply -f -

  if helm status confluent-operator -n "${CONFLUENT_NAMESPACE}" &>/dev/null; then
    info "CFK operator already installed — upgrading..."
    run helm upgrade confluent-operator "${CFK_CHART}" \
      --namespace "${CONFLUENT_NAMESPACE}" \
      --version "${CFK_VERSION}" \
      --reuse-values
  else
    info "Installing CFK operator (version ${CFK_VERSION})..."
    run helm install confluent-operator "${CFK_CHART}" \
      --namespace "${CONFLUENT_NAMESPACE}" \
      --version "${CFK_VERSION}" \
      --set namespaced=true \
      --wait \
      --timeout 300s
  fi

  info "CFK operator deployed. Waiting for operator pod to be ready..."
  run kubectl rollout status deployment/confluent-operator \
    -n "${CONFLUENT_NAMESPACE}" \
    --timeout=120s
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  if [[ "${DRY_RUN}" == "--help" || "${DRY_RUN}" == "-h" ]]; then
    usage
    exit 0
  fi

  check_prerequisites
  create_cluster
  wait_for_nodes
  add_helm_repo
  install_cfk_operator

  cat <<EOF

[INFO]  ============================================================
[INFO]  K3D cluster '${CLUSTER_NAME}' is ready.
[INFO]
[INFO]  Next steps:
[INFO]    1. Generate mTLS certificates:
[INFO]       ./confluent/mtls/generate-certs.sh
[INFO]    2. Create K8s secrets:
[INFO]       ./confluent/mtls/create-k8s-secrets.sh
[INFO]    3. Deploy Confluent Platform (KRaft):
[INFO]       kubectl apply -f confluent/namespace.yaml
[INFO]       kubectl apply -f confluent/confluent-platform.yaml
[INFO]
[INFO]  Or run everything at once:
[INFO]       ./scripts/setup-all.sh
[INFO]  ============================================================

EOF
}

main "$@"
