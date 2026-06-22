#!/usr/bin/env bash
# deploy-optional.sh — Deploy optional Confluent components
#
# Deploys Schema Registry and Control Center Next Gen (with embedded Prometheus
# and AlertManager). Patches Kafka and KRaft to report metrics to Prometheus.
#
# Usage:
#   ./scripts/deploy-optional.sh [--no-port-forward]
#
# Options:
#   --no-port-forward   Deploy components but skip starting port-forwards
#
# Access after deployment:
#   Schema Registry:  https://localhost:8081
#   Control Center:   https://localhost:9021
#
# Prerequisites:
#   - Kafka cluster already running (./scripts/setup-all.sh completed)
#   - certs/ directory populated (generate-certs.sh already run)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CERTS_DIR="${CERTS_DIR:-${REPO_ROOT}/certs}"
NAMESPACE="${NAMESPACE:-confluent}"
CERT_VALIDITY_DAYS="${CERT_VALIDITY_DAYS:-3650}"
PORT_FORWARD=true

for arg in "$@"; do
  [[ "${arg}" == "--no-port-forward" ]] && PORT_FORWARD=false
done

info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
error()   { echo "[ERROR] $*" >&2; exit 1; }

wait_for_running() {
  local resource="$1" timeout="${2:-600}"
  local elapsed=0 interval=15
  info "Waiting for ${resource} to be ready (timeout: ${timeout}s)..."
  while true; do
    local phase
    phase=$(kubectl get "${resource}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${phase}" == "RUNNING" ]]; then
      success "${resource} is ready (phase=RUNNING)."
      return 0
    fi
    if (( elapsed >= timeout )); then
      error "${resource} did not reach RUNNING within ${timeout}s (current phase: ${phase:-unknown})"
    fi
    info "  ${resource} phase=${phase:-unknown}, waiting... (${elapsed}s elapsed)"
    sleep "${interval}"
    elapsed=$(( elapsed + interval ))
  done
}

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
for cmd in openssl keytool kubectl; do
  command -v "${cmd}" &>/dev/null || error "Required tool not found: ${cmd}"
done

[[ -f "${CERTS_DIR}/ca/ca.crt" ]] || error "CA cert not found. Run generate-certs.sh first."
[[ -f "${CERTS_DIR}/ca/ca.key" ]] || error "CA key not found. Run generate-certs.sh first."

kubectl get namespace "${NAMESPACE}" &>/dev/null || error "Namespace '${NAMESPACE}' not found. Run setup-all.sh first."
kubectl get kafka kafka -n "${NAMESPACE}" &>/dev/null         || error "Kafka CR not found. Run setup-all.sh first."
kubectl get kraftcontroller kraftcontroller -n "${NAMESPACE}" &>/dev/null || error "KRaftController CR not found. Run setup-all.sh first."

# ---------------------------------------------------------------------------
# Helper: generate a TLS cert signed by the existing CA
# ---------------------------------------------------------------------------
generate_cert() {
  local name="$1" cn="$2" eku="${3:-serverAuth}" extra_sans="${4:-}"
  local out_dir="${CERTS_DIR}/${name}"
  mkdir -p "${out_dir}"
  info "Generating TLS cert for ${name} (CN=${cn}, EKU=${eku})..."

  local san="DNS:${name},DNS:${name}.${NAMESPACE}.svc.cluster.local,DNS:controlcenter-next-gen,DNS:controlcenter-next-gen.${NAMESPACE}.svc.cluster.local,DNS:localhost"
  [[ -n "${extra_sans}" ]] && san="${san},${extra_sans}"

  openssl genrsa -out "${out_dir}/${name}.key" 2048

  openssl req -new \
    -key "${out_dir}/${name}.key" \
    -out "${out_dir}/${name}.csr" \
    -subj "/C=GB/ST=England/L=London/O=OMB Confluent Benchmark/OU=Platform/CN=${cn}" \
    -addext "subjectAltName=${san}" \
    -addext "extendedKeyUsage=${eku}" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment"

  openssl x509 -req \
    -in "${out_dir}/${name}.csr" \
    -CA "${CERTS_DIR}/ca/ca.crt" \
    -CAkey "${CERTS_DIR}/ca/ca.key" \
    -CAcreateserial \
    -out "${out_dir}/${name}.crt" \
    -days "${CERT_VALIDITY_DAYS}" \
    -sha256 \
    -copy_extensions copyall

  openssl verify -CAfile "${CERTS_DIR}/ca/ca.crt" "${out_dir}/${name}.crt"
  success "  ${out_dir}/${name}.crt"
}

# ---------------------------------------------------------------------------
# Helper: create K8s TLS secret — CFK Group 1 format (fullchain.pem/privkey.pem/cacerts.pem)
# ---------------------------------------------------------------------------
apply_tls_secret() {
  local secret_name="$1" cert="$2" key="$3"
  local fullchain
  fullchain="$(mktemp)"
  cat "${cert}" "${CERTS_DIR}/ca/ca.crt" > "${fullchain}"
  info "Applying secret '${secret_name}'..."
  kubectl create secret generic "${secret_name}" \
    --from-file=fullchain.pem="${fullchain}" \
    --from-file=privkey.pem="${key}" \
    --from-file=cacerts.pem="${CERTS_DIR}/ca/ca.crt" \
    -n "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -f "${fullchain}"
  success "  secret/${secret_name} applied."
}

# ---------------------------------------------------------------------------
# Helper: create K8s TLS secret — CFK Group 2 format (keystore.jks/truststore.jks/jksPassword.txt)
#
# CFK mounts these files as-is (no init-container PKCS12 conversion). Both are
# standard PKCS12 containers named .jks for CFK compatibility. The keystore is
# available if metricsClient.authentication.type=mtls is ever added; without it,
# CFK only generates ssl.truststore.* in kafka.properties.
# ---------------------------------------------------------------------------
apply_jks_secret() {
  local secret_name="$1" cert="$2" key="$3"
  local ks ts pw_file
  ks="$(mktemp --suffix=.jks)" ts="$(mktemp --suffix=.jks)" pw_file="$(mktemp)"

  # keystore: leaf cert + CA chain
  local fullchain
  fullchain="$(mktemp)"
  cat "${cert}" "${CERTS_DIR}/ca/ca.crt" > "${fullchain}"
  openssl pkcs12 -export \
    -in "${fullchain}" -inkey "${key}" \
    -out "${ks}" -name "prom-shared" -passout pass:changeit

  # truststore: CA cert only
  keytool -importcert -alias caroot \
    -file "${CERTS_DIR}/ca/ca.crt" \
    -keystore "${ts}" -storetype PKCS12 \
    -storepass changeit -noprompt

  echo -n "jksPassword=changeit" > "${pw_file}"

  info "Applying JKS secret '${secret_name}'..."
  kubectl create secret generic "${secret_name}" \
    --from-file=keystore.jks="${ks}" \
    --from-file=truststore.jks="${ts}" \
    --from-file=jksPassword.txt="${pw_file}" \
    -n "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -f "${ks}" "${ts}" "${pw_file}" "${fullchain}"
  success "  secret/${secret_name} applied."
}

# ---------------------------------------------------------------------------
# 1. Generate certificates
# ---------------------------------------------------------------------------
info "============================================================"
info "Generating TLS certificates..."
info "============================================================"

generate_cert "schemaregistry" "schemaregistry"        "serverAuth,clientAuth"
generate_cert "controlcenter"  "controlcenter-next-gen" "serverAuth,clientAuth"

# Single shared cert for all Prometheus/AlertManager secrets (server + client).
# Uses CFK Group 2 JKS format for prometheus-client-tls so the cp-server shaded
# telemetry client can load the keystore directly and present a client cert.
# Prometheus itself runs TLS-only (no mTLS enforcement) since CFK does not expose
# client_ca_file/client_auth_type in the ControlCenter services.prometheus spec.
generate_cert "prom-shared" "controlcenter-next-gen" "serverAuth,clientAuth" \
  "DNS:prometheus,DNS:prometheus.${NAMESPACE}.svc.cluster.local,DNS:alertmanager,DNS:alertmanager.${NAMESPACE}.svc.cluster.local,DNS:*.${NAMESPACE}.svc.cluster.local"

# ---------------------------------------------------------------------------
# 2. Create Kubernetes secrets
# ---------------------------------------------------------------------------
info "============================================================"
info "Creating Kubernetes secrets..."
info "============================================================"

apply_tls_secret "schemaregistry-tls" \
  "${CERTS_DIR}/schemaregistry/schemaregistry.crt" \
  "${CERTS_DIR}/schemaregistry/schemaregistry.key"

apply_tls_secret "controlcenter-tls" \
  "${CERTS_DIR}/controlcenter/controlcenter.crt" \
  "${CERTS_DIR}/controlcenter/controlcenter.key"

# Server-side secrets: Group 1 PEM format (CFK generates PKCS12 from PEM).
for secret in prometheus-tls alertmanager-tls alertmanager-client-tls; do
  apply_tls_secret "${secret}" \
    "${CERTS_DIR}/prom-shared/prom-shared.crt" \
    "${CERTS_DIR}/prom-shared/prom-shared.key"
done

# prometheus-client-tls: Group 2 JKS format. Without authentication.type=mtls in
# the metricsClient, CFK generates only ssl.truststore.* in kafka.properties (not
# ssl.keystore.*). The shaded client uses its own SSLContext and does not honour
# the configured truststore for server-cert verification, so KAFKA_OPTS (Section 6)
# injects the CA directly into the JVM default trust chain.
apply_jks_secret "prometheus-client-tls" \
  "${CERTS_DIR}/prom-shared/prom-shared.crt" \
  "${CERTS_DIR}/prom-shared/prom-shared.key"

# ---------------------------------------------------------------------------
# 3. Remove classic Control Center if it exists
# ---------------------------------------------------------------------------
if kubectl get controlcenter controlcenter -n "${NAMESPACE}" &>/dev/null; then
  info "Removing classic Control Center before deploying Next Gen..."
  kubectl delete controlcenter controlcenter -n "${NAMESPACE}"
  kubectl wait --for=delete controlcenter/controlcenter -n "${NAMESPACE}" --timeout=120s || true
  pkill -f "port-forward svc/controlcenter " 2>/dev/null || true
  success "Classic Control Center removed."
fi

# ---------------------------------------------------------------------------
# 4. Deploy Schema Registry
# ---------------------------------------------------------------------------
info "============================================================"
info "Deploying Schema Registry..."
info "============================================================"

kubectl apply -f "${REPO_ROOT}/confluent/optional/schema-registry.yaml"
wait_for_running "schemaregistry/schemaregistry" 300

# ---------------------------------------------------------------------------
# 5. Deploy Control Center Next Gen
# ---------------------------------------------------------------------------
info "============================================================"
info "Deploying Control Center Next Gen (this can take a few minutes)..."
info "============================================================"

kubectl apply -f "${REPO_ROOT}/confluent/optional/control-center.yaml"
wait_for_running "controlcenter/controlcenter-next-gen" 600

# ---------------------------------------------------------------------------
# 6. Patch Kafka and KRaft with metricsClient + KAFKA_OPTS trustStore
# ---------------------------------------------------------------------------
# Prometheus runs TLS-only (not mTLS). cp-server 7.x's shaded telemetry client
# creates its own SSLContext and does not use the configured ssl.truststore.*
# properties for server-cert verification. KAFKA_OPTS injects our CA into the
# JVM default trust chain so the shaded client can verify Prometheus's TLS cert.
# Upgrading to cp-server 7.9+ would enable full mTLS via metricsClient.authentication.
info "============================================================"
info "Patching Kafka and KRaft with metricsClient dependency..."
info "============================================================"

PROM_URL="https://controlcenter-next-gen.${NAMESPACE}.svc.cluster.local:9090"
KAFKA_OPTS_VAL="-Djavax.net.ssl.trustStore=/mnt/sslcerts/prometheus-client-tls/truststore.jks -Djavax.net.ssl.trustStorePassword=changeit -Djavax.net.ssl.trustStoreType=PKCS12"

kubectl patch kafka kafka -n "${NAMESPACE}" --type=merge -p "{
  \"spec\": {
    \"dependencies\": {
      \"metricsClient\": {
        \"url\": \"${PROM_URL}\",
        \"tls\": {\"enabled\": true, \"secretRef\": \"prometheus-client-tls\"}
      }
    },
    \"podTemplate\": {
      \"envVars\": [{\"name\": \"KAFKA_OPTS\", \"value\": \"${KAFKA_OPTS_VAL}\"}]
    }
  }
}"
success "Kafka patched with metricsClient."

kubectl patch kraftcontroller kraftcontroller -n "${NAMESPACE}" --type=merge -p "{
  \"spec\": {
    \"dependencies\": {
      \"metricsClient\": {
        \"url\": \"${PROM_URL}\",
        \"tls\": {\"enabled\": true, \"secretRef\": \"prometheus-client-tls\"}
      }
    },
    \"podTemplate\": {
      \"envVars\": [{\"name\": \"KAFKA_OPTS\", \"value\": \"${KAFKA_OPTS_VAL}\"}]
    }
  }
}"
success "KRaftController patched with metricsClient."

# ---------------------------------------------------------------------------
# 8. Port-forward services
# ---------------------------------------------------------------------------
if [[ "${PORT_FORWARD}" == "true" ]]; then
  info "Starting port-forwards..."

  pkill -f "port-forward svc/schemaregistry"     2>/dev/null || true
  pkill -f "port-forward svc/controlcenter-next-gen" 2>/dev/null || true
  sleep 1

  kubectl port-forward svc/schemaregistry 8081:8081 -n "${NAMESPACE}" \
    > /tmp/pf-schemaregistry.log 2>&1 &
  SR_PF_PID=$!

  kubectl port-forward svc/controlcenter-next-gen 9021:9021 -n "${NAMESPACE}" \
    > /tmp/pf-controlcenter.log 2>&1 &
  CC_PF_PID=$!

  sleep 2

  kill -0 "${SR_PF_PID}" 2>/dev/null \
    && success "Schema Registry port-forward running (PID ${SR_PF_PID})" \
    || error "Schema Registry port-forward failed — check /tmp/pf-schemaregistry.log"
  kill -0 "${CC_PF_PID}" 2>/dev/null \
    && success "Control Center port-forward running (PID ${CC_PF_PID})" \
    || error "Control Center port-forward failed — check /tmp/pf-controlcenter.log"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat <<EOF

[INFO]  ============================================================
[INFO]  Optional components deployed successfully.
[INFO]
[INFO]  Schema Registry:
[INFO]    Internal: https://schemaregistry.confluent.svc.cluster.local:8081
EOF
if [[ "${PORT_FORWARD}" == "true" ]]; then
  echo "[INFO]    External: https://localhost:8081  (port-forward active)"
  echo "[INFO]    Test:     curl -k https://localhost:8081/subjects"
else
  echo "[INFO]    Access:   kubectl port-forward svc/schemaregistry 8081:8081 -n ${NAMESPACE}"
fi
cat <<EOF
[INFO]
[INFO]  Control Center Next Gen:
[INFO]    Internal: https://controlcenter-next-gen.confluent.svc.cluster.local:9021
EOF
if [[ "${PORT_FORWARD}" == "true" ]]; then
  echo "[INFO]    External: https://localhost:9021  (port-forward active)"
else
  echo "[INFO]    Access:   kubectl port-forward svc/controlcenter-next-gen 9021:9021 -n ${NAMESPACE}"
fi
cat <<EOF
[INFO]
[INFO]  To stop port-forwards:
[INFO]    pkill -f "port-forward svc/schemaregistry"
[INFO]    pkill -f "port-forward svc/controlcenter-next-gen"
[INFO]
[INFO]  To remove optional components:
[INFO]    kubectl delete -f confluent/optional/
[INFO]    kubectl delete secret schemaregistry-tls controlcenter-tls \\
[INFO]      prometheus-tls alertmanager-tls \\
[INFO]      prometheus-client-tls alertmanager-client-tls -n ${NAMESPACE}
[INFO]  ============================================================

EOF
