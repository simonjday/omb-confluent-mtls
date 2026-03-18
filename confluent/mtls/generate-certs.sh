#!/usr/bin/env bash
# generate-certs.sh — Generate mTLS certificates for the Confluent Platform
#
# Generates:
#   CA key + self-signed certificate
#   Kafka broker key, CSR, certificate (signed by CA, with SANs)
#   KRaft controller key, CSR, certificate (signed by CA, with SANs)
#   OMB client key, CSR, certificate (signed by CA)
#   JKS keystores and truststores for broker, controller, and client
#
# Output directory: <repo-root>/certs/
#
# Usage:
#   ./confluent/mtls/generate-certs.sh
#
# Environment variables (all optional):
#   KEYSTORE_PASSWORD    — Password for JKS keystores  (default: changeit)
#   TRUSTSTORE_PASSWORD  — Password for JKS truststores (default: changeit)
#   KEY_PASSWORD         — Password for private keys    (default: changeit)
#   CERT_VALIDITY_DAYS   — Certificate validity in days (default: 3650)
#   CERTS_DIR            — Output directory             (default: <repo-root>/certs)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OPENSSL_CNF="${SCRIPT_DIR}/openssl.cnf"

CERTS_DIR="${CERTS_DIR:-${REPO_ROOT}/certs}"
KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD:-changeit}"
TRUSTSTORE_PASSWORD="${TRUSTSTORE_PASSWORD:-changeit}"
KEY_PASSWORD="${KEY_PASSWORD:-changeit}"
CERT_VALIDITY_DAYS="${CERT_VALIDITY_DAYS:-3650}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# Check required tools
for cmd in openssl keytool; do
  command -v "${cmd}" &>/dev/null || error "Required tool not found: ${cmd}"
done

usage() {
  cat <<EOF
Usage: $(basename "$0")

Generate mTLS certificates for Kafka brokers, KRaft controllers, and OMB clients.

Environment variables:
  KEYSTORE_PASSWORD    JKS keystore password   (default: changeit)
  TRUSTSTORE_PASSWORD  JKS truststore password (default: changeit)
  KEY_PASSWORD         Private key password    (default: changeit)
  CERT_VALIDITY_DAYS   Certificate validity    (default: 3650)
  CERTS_DIR            Output directory        (default: <repo-root>/certs)

EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage; exit 0
fi

# ---------------------------------------------------------------------------
# 1. Create output directory structure
# ---------------------------------------------------------------------------
info "Creating output directory: ${CERTS_DIR}"
mkdir -p "${CERTS_DIR}"/{ca,broker,kraftcontroller,client}

# ---------------------------------------------------------------------------
# 2. Generate CA key and self-signed certificate
# ---------------------------------------------------------------------------
info "Generating CA key and certificate..."
openssl genrsa -out "${CERTS_DIR}/ca/ca.key" 4096

openssl req -new -x509 \
  -key "${CERTS_DIR}/ca/ca.key" \
  -out "${CERTS_DIR}/ca/ca.crt" \
  -days "${CERT_VALIDITY_DAYS}" \
  -config "${OPENSSL_CNF}" \
  -extensions v3_ca \
  -subj "/C=GB/ST=England/L=London/O=OMB Confluent Benchmark/OU=Platform Engineering/CN=OMB Root CA"

info "CA certificate: ${CERTS_DIR}/ca/ca.crt"

# ---------------------------------------------------------------------------
# 3. Generate Kafka broker certificate (with SANs)
# ---------------------------------------------------------------------------
info "Generating Kafka broker certificate..."

openssl genrsa -out "${CERTS_DIR}/broker/broker.key" 4096

openssl req -new \
  -key "${CERTS_DIR}/broker/broker.key" \
  -out "${CERTS_DIR}/broker/broker.csr" \
  -config "${OPENSSL_CNF}" \
  -reqexts broker_san \
  -subj "/C=GB/ST=England/L=London/O=OMB Confluent Benchmark/OU=Kafka/CN=kafka"

openssl x509 -req \
  -in "${CERTS_DIR}/broker/broker.csr" \
  -CA "${CERTS_DIR}/ca/ca.crt" \
  -CAkey "${CERTS_DIR}/ca/ca.key" \
  -CAcreateserial \
  -out "${CERTS_DIR}/broker/broker.crt" \
  -days "${CERT_VALIDITY_DAYS}" \
  -sha256 \
  -extfile "${OPENSSL_CNF}" \
  -extensions broker_cert_ext

info "Broker certificate: ${CERTS_DIR}/broker/broker.crt"

# Verify broker cert
openssl verify -CAfile "${CERTS_DIR}/ca/ca.crt" "${CERTS_DIR}/broker/broker.crt"

# ---------------------------------------------------------------------------
# 4. Generate KRaft controller certificate (with SANs)
# ---------------------------------------------------------------------------
info "Generating KRaft controller certificate..."

openssl genrsa -out "${CERTS_DIR}/kraftcontroller/kraftcontroller.key" 4096

openssl req -new \
  -key "${CERTS_DIR}/kraftcontroller/kraftcontroller.key" \
  -out "${CERTS_DIR}/kraftcontroller/kraftcontroller.csr" \
  -config "${OPENSSL_CNF}" \
  -reqexts kraftcontroller_san \
  -subj "/C=GB/ST=England/L=London/O=OMB Confluent Benchmark/OU=KRaft/CN=kraftcontroller"

openssl x509 -req \
  -in "${CERTS_DIR}/kraftcontroller/kraftcontroller.csr" \
  -CA "${CERTS_DIR}/ca/ca.crt" \
  -CAkey "${CERTS_DIR}/ca/ca.key" \
  -CAcreateserial \
  -out "${CERTS_DIR}/kraftcontroller/kraftcontroller.crt" \
  -days "${CERT_VALIDITY_DAYS}" \
  -sha256 \
  -extfile "${OPENSSL_CNF}" \
  -extensions kraftcontroller_cert_ext

info "KRaft controller certificate: ${CERTS_DIR}/kraftcontroller/kraftcontroller.crt"
openssl verify -CAfile "${CERTS_DIR}/ca/ca.crt" "${CERTS_DIR}/kraftcontroller/kraftcontroller.crt"

# ---------------------------------------------------------------------------
# 5. Generate OMB client certificate
# ---------------------------------------------------------------------------
info "Generating OMB client certificate..."

openssl genrsa -out "${CERTS_DIR}/client/client.key" 4096

openssl req -new \
  -key "${CERTS_DIR}/client/client.key" \
  -out "${CERTS_DIR}/client/client.csr" \
  -config "${OPENSSL_CNF}" \
  -reqexts client_san \
  -subj "/C=GB/ST=England/L=London/O=OMB Confluent Benchmark/OU=OMB/CN=omb-client"

openssl x509 -req \
  -in "${CERTS_DIR}/client/client.csr" \
  -CA "${CERTS_DIR}/ca/ca.crt" \
  -CAkey "${CERTS_DIR}/ca/ca.key" \
  -CAcreateserial \
  -out "${CERTS_DIR}/client/client.crt" \
  -days "${CERT_VALIDITY_DAYS}" \
  -sha256 \
  -extfile "${OPENSSL_CNF}" \
  -extensions client_cert_ext

info "Client certificate: ${CERTS_DIR}/client/client.crt"
openssl verify -CAfile "${CERTS_DIR}/ca/ca.crt" "${CERTS_DIR}/client/client.crt"

# ---------------------------------------------------------------------------
# Helper: create_jks_keystore <name> <key> <cert> <ca-cert> <output-dir>
# Creates a PKCS12 bundle then converts to JKS keystore
# ---------------------------------------------------------------------------
create_jks_keystore() {
  local name="$1"
  local key="$2"
  local cert="$3"
  local ca_cert="$4"
  local out_dir="$5"

  info "Creating JKS keystore for ${name}..."

  # PKCS12 intermediate
  openssl pkcs12 -export \
    -in "${cert}" \
    -inkey "${key}" \
    -chain \
    -CAfile "${ca_cert}" \
    -name "${name}" \
    -out "${out_dir}/${name}.p12" \
    -passout "pass:${KEY_PASSWORD}"

  # Convert PKCS12 → JKS
  keytool -importkeystore \
    -deststorepass "${KEYSTORE_PASSWORD}" \
    -destkeypass "${KEY_PASSWORD}" \
    -destkeystore "${out_dir}/${name}.keystore.jks" \
    -srckeystore "${out_dir}/${name}.p12" \
    -srcstoretype PKCS12 \
    -srcstorepass "${KEY_PASSWORD}" \
    -alias "${name}" \
    -noprompt

  info "  Keystore: ${out_dir}/${name}.keystore.jks"
}

# ---------------------------------------------------------------------------
# Helper: create_jks_truststore <name> <ca-cert> <output-dir>
# ---------------------------------------------------------------------------
create_jks_truststore() {
  local name="$1"
  local ca_cert="$2"
  local out_dir="$3"

  info "Creating JKS truststore for ${name}..."

  keytool -import \
    -alias "ca" \
    -file "${ca_cert}" \
    -keystore "${out_dir}/${name}.truststore.jks" \
    -storepass "${TRUSTSTORE_PASSWORD}" \
    -noprompt

  info "  Truststore: ${out_dir}/${name}.truststore.jks"
}

# ---------------------------------------------------------------------------
# 6. Create JKS keystores and truststores
# ---------------------------------------------------------------------------
info "Creating JKS keystores and truststores..."

# Broker
create_jks_keystore "broker" \
  "${CERTS_DIR}/broker/broker.key" \
  "${CERTS_DIR}/broker/broker.crt" \
  "${CERTS_DIR}/ca/ca.crt" \
  "${CERTS_DIR}/broker"
create_jks_truststore "broker" "${CERTS_DIR}/ca/ca.crt" "${CERTS_DIR}/broker"

# KRaft controller
create_jks_keystore "kraftcontroller" \
  "${CERTS_DIR}/kraftcontroller/kraftcontroller.key" \
  "${CERTS_DIR}/kraftcontroller/kraftcontroller.crt" \
  "${CERTS_DIR}/ca/ca.crt" \
  "${CERTS_DIR}/kraftcontroller"
create_jks_truststore "kraftcontroller" "${CERTS_DIR}/ca/ca.crt" "${CERTS_DIR}/kraftcontroller"

# Client (OMB)
create_jks_keystore "client" \
  "${CERTS_DIR}/client/client.key" \
  "${CERTS_DIR}/client/client.crt" \
  "${CERTS_DIR}/ca/ca.crt" \
  "${CERTS_DIR}/client"
create_jks_truststore "client" "${CERTS_DIR}/ca/ca.crt" "${CERTS_DIR}/client"

# Copy client JKS files to top-level certs/ for easy docker volume mounting
cp "${CERTS_DIR}/client/client.keystore.jks"   "${CERTS_DIR}/client.keystore.jks"
cp "${CERTS_DIR}/client/client.truststore.jks" "${CERTS_DIR}/client.truststore.jks"

# ---------------------------------------------------------------------------
# 7. Print summary
# ---------------------------------------------------------------------------
cat <<EOF

[INFO]  ============================================================
[INFO]  Certificate generation complete.
[INFO]
[INFO]  Directory: ${CERTS_DIR}
[INFO]
[INFO]  CA:
[INFO]    ${CERTS_DIR}/ca/ca.key
[INFO]    ${CERTS_DIR}/ca/ca.crt
[INFO]
[INFO]  Kafka broker:
[INFO]    ${CERTS_DIR}/broker/broker.key
[INFO]    ${CERTS_DIR}/broker/broker.crt
[INFO]    ${CERTS_DIR}/broker/broker.keystore.jks
[INFO]    ${CERTS_DIR}/broker/broker.truststore.jks
[INFO]
[INFO]  KRaft controller:
[INFO]    ${CERTS_DIR}/kraftcontroller/kraftcontroller.key
[INFO]    ${CERTS_DIR}/kraftcontroller/kraftcontroller.crt
[INFO]    ${CERTS_DIR}/kraftcontroller/kraftcontroller.keystore.jks
[INFO]    ${CERTS_DIR}/kraftcontroller/kraftcontroller.truststore.jks
[INFO]
[INFO]  OMB client:
[INFO]    ${CERTS_DIR}/client/client.key
[INFO]    ${CERTS_DIR}/client/client.crt
[INFO]    ${CERTS_DIR}/client.keystore.jks    (mounted into OMB containers)
[INFO]    ${CERTS_DIR}/client.truststore.jks  (mounted into OMB containers)
[INFO]
[INFO]  Keystore password:    ${KEYSTORE_PASSWORD}
[INFO]  Truststore password:  ${TRUSTSTORE_PASSWORD}
[INFO]
[INFO]  Next step:
[INFO]    ./confluent/mtls/create-k8s-secrets.sh
[INFO]  ============================================================

EOF
