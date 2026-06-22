#!/usr/bin/env bash
# resume.sh — Resume a suspended benchmark platform
#
# Restarts the K3D cluster and waits for all Confluent pods to be ready.
# Optionally starts port-forwards for Schema Registry and Control Center.
#
# Usage:
#   ./scripts/resume.sh [--no-port-forward]
#
# Options:
#   --no-port-forward   Start cluster but skip port-forwards

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_NAME="confluent-benchmark"
NAMESPACE="${NAMESPACE:-confluent}"
PORT_FORWARD=true
POD_TIMEOUT=300

for arg in "$@"; do
  [[ "${arg}" == "--no-port-forward" ]] && PORT_FORWARD=false
done

info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*" >&2; }
error()   { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Start the K3D cluster
# ---------------------------------------------------------------------------
command -v k3d &>/dev/null || error "k3d not found"

if ! k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME}"; then
  error "Cluster '${CLUSTER_NAME}' not found. Run ./scripts/setup-all.sh to create it."
fi

info "Starting K3D cluster '${CLUSTER_NAME}'..."
k3d cluster start "${CLUSTER_NAME}"
# Node IPs change on each start — merge a fresh kubeconfig so kubectl
# connects to the new IPs and port-forwards work correctly.
k3d kubeconfig merge "${CLUSTER_NAME}" --kubeconfig-merge-default >/dev/null

# The kubelet serving cert (serving-kubelet.crt) embeds the node's IP in its SANs.
# After a restart the IPs change, making the old cert invalid — kubectl port-forward
# fails with "x509: certificate is valid for <old-ip>, not <new-ip>".
# Deleting the cert forces K3s to regenerate it with the current IP on next use.
info "Rotating stale kubelet serving certs (node IPs change on restart)..."
for _node in $(docker ps --filter "name=k3d-${CLUSTER_NAME}-agent" --format '{{.Names}}'); do
  docker exec "${_node}" rm -f \
    /var/lib/rancher/k3s/agent/serving-kubelet.crt \
    /var/lib/rancher/k3s/agent/serving-kubelet.key 2>/dev/null || true
done
unset _node
success "Cluster started."

# ---------------------------------------------------------------------------
# 2. Wait for Kafka and KRaft pods to be Running
# ---------------------------------------------------------------------------
info "Waiting for Confluent pods to be ready (timeout: ${POD_TIMEOUT}s)..."
elapsed=0
interval=10

while true; do
  # Count pods that are NOT Running or Completed (kubectl may fail while API server warms up)
  pod_output=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null || true)
  not_ready=$(echo "${pod_output}" | grep -v -E "Running|Completed" | grep -c "." || true)
  total=$(echo "${pod_output}" | grep -c "." || true)

  if [[ "${total}" -gt 0 && "${not_ready}" -eq 0 ]]; then
    success "All ${total} pods are Running."
    break
  fi

  if (( elapsed >= POD_TIMEOUT )); then
    warn "Timed out waiting for pods — some may still be starting."
    kubectl get pods -n "${NAMESPACE}" 2>/dev/null || true
    break
  fi

  info "  ${not_ready}/${total} pods not yet ready... (${elapsed}s elapsed)"
  sleep "${interval}"
  elapsed=$(( elapsed + interval ))
done

# ---------------------------------------------------------------------------
# 3. Show Kafka and KRaft phase
# ---------------------------------------------------------------------------
kafka_phase=$(kubectl get kafka kafka -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
kraft_phase=$(kubectl get kraftcontroller kraftcontroller -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
info "Kafka phase: ${kafka_phase}  |  KRaftController phase: ${kraft_phase}"

# ---------------------------------------------------------------------------
# 4. Port-forward optional services if they are deployed
# ---------------------------------------------------------------------------
if [[ "${PORT_FORWARD}" == "true" ]]; then
  # Kill any stale port-forwards first
  pkill -f "port-forward svc/schemaregistry"         2>/dev/null || true
  pkill -f "port-forward svc/controlcenter-next-gen" 2>/dev/null || true
  sleep 1

  if kubectl get svc schemaregistry -n "${NAMESPACE}" &>/dev/null; then
    kubectl port-forward svc/schemaregistry 8081:8081 -n "${NAMESPACE}" \
      > /tmp/pf-schemaregistry.log 2>&1 &
    SR_PID=$!
    sleep 1
    kill -0 "${SR_PID}" 2>/dev/null \
      && success "Schema Registry port-forward running (https://localhost:8081)" \
      || warn "Schema Registry port-forward failed — check /tmp/pf-schemaregistry.log"
  fi

  if kubectl get svc controlcenter-next-gen -n "${NAMESPACE}" &>/dev/null; then
    kubectl port-forward svc/controlcenter-next-gen 9021:9021 -n "${NAMESPACE}" \
      > /tmp/pf-controlcenter.log 2>&1 &
    CC_PID=$!
    sleep 1
    kill -0 "${CC_PID}" 2>/dev/null \
      && success "Control Center port-forward running  (https://localhost:9021)" \
      || warn "Control Center port-forward failed — check /tmp/pf-controlcenter.log"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat <<EOF

[INFO]  ============================================================
[INFO]  Platform resumed.
[INFO]
[INFO]  Kafka brokers:   localhost:9093 localhost:9094 localhost:9095
EOF
if kubectl get svc schemaregistry -n "${NAMESPACE}" &>/dev/null && [[ "${PORT_FORWARD}" == "true" ]]; then
  echo "[INFO]  Schema Registry: https://localhost:8081"
fi
if kubectl get svc controlcenter-next-gen -n "${NAMESPACE}" &>/dev/null && [[ "${PORT_FORWARD}" == "true" ]]; then
  echo "[INFO]  Control Center:  https://localhost:9021"
fi
cat <<EOF
[INFO]
[INFO]  Run a benchmark:  ./scripts/run-benchmark.sh simple-workload
[INFO]  Suspend again:    ./scripts/suspend.sh
[INFO]  Full teardown:    ./scripts/teardown.sh
[INFO]  ============================================================

EOF
