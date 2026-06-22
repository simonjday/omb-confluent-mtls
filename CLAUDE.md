# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

End-to-end benchmark platform for load-testing a **mTLS-enabled Confluent Platform** cluster (pure KRaft, no ZooKeeper) running in K3D (Docker-based Kubernetes), using Open Messaging Benchmark (OMB).

## Key Commands

```bash
# Full setup (K3D cluster + CFK operator + certs + Confluent + OMB image)
./scripts/setup-all.sh

# Run a benchmark (starts workers then driver)
./scripts/run-benchmark.sh simple-workload   # smoke test
./scripts/run-benchmark.sh high-throughput   # 100k msg/s
./scripts/run-benchmark.sh low-latency       # 512B messages
./scripts/run-benchmark.sh endurance         # 30-min stability

# Summarise results
./scripts/collect-results.sh

# Teardown
./scripts/teardown.sh           # stop containers + delete cluster
./scripts/teardown.sh --all     # also remove certs/ and results/
```

## Architecture

```
K3D cluster (Docker)
  └── confluent namespace
        ├── KRaftController (3 replicas) — Raft quorum, no ZooKeeper
        └── Kafka brokers   (3 replicas) — mTLS, NodePorts 30093-30095

Host ports 9093-9095 ← K3D LoadBalancer ← NodePorts

Docker Compose (host network)
  ├── omb-worker-1 :8080
  ├── omb-worker-2 :8081
  ├── omb-worker-3 :8082
  └── omb-driver   (orchestrates workers, connects to Kafka via mTLS)
```

All OMB containers use `network_mode: host` and mount `certs/` with JKS keystores.

## Directory Map

| Path | Purpose |
|------|---------|
| `docker/Dockerfile` | Single unified `omb:latest` image (worker + driver) |
| `docker/docker-compose.yml` | 3 workers + 1 driver |
| `k3d/` | Cluster config + setup script (creates cluster, installs CFK via Helm) |
| `confluent/confluent-platform.yaml` | KRaftController + Kafka CRs |
| `confluent/mtls/generate-certs.sh` | Generates CA, broker, controller, client certs + JKS stores |
| `confluent/mtls/create-k8s-secrets.sh` | Loads certs into K8s secrets |
| `confluent/mtls/openssl.cnf` | OpenSSL config with SANs for all endpoints |
| `omb/driver-kafka.yaml` | Kafka driver config (bootstrap servers, mTLS keystore paths) |
| `omb/workers.yaml` | Worker HTTP endpoints |
| `omb/workloads/` | Workload YAML files (topics, rate, messageSize, duration) |
| `scripts/` | Orchestration scripts |
| `certs/` | Generated certs — gitignored, created by `generate-certs.sh` |
| `results/` | JSON benchmark output — gitignored |

## TLS / Certificate Flow

`generate-certs.sh` creates a self-signed CA and signs broker, controller, and client certs. Client-side JKS stores (`client.keystore.jks`, `client.truststore.jks`) are mounted into OMB containers. Broker-side certs are loaded as K8s secrets (`kafka-tls`, `kraftcontroller-tls`).

Default passwords for all JKS stores: `changeit` (override via `.env`).

## Kafka External Access

| Broker | Host port | NodePort |
|--------|-----------|----------|
| kafka-0 | 9093 | 30093 |
| kafka-1 | 9094 | 30094 |
| kafka-2 | 9095 | 30095 |

## Adding Workers

1. Add a service to `docker/docker-compose.yml` on a new port (e.g. 8083).
2. Add the endpoint to `omb/workers.yaml`.

## Environment Variables

Create a `.env` in repo root (gitignored):

```bash
KAFKA_BOOTSTRAP_SERVERS=localhost:9093,localhost:9094,localhost:9095
KEYSTORE_PASSWORD=changeit
TRUSTSTORE_PASSWORD=changeit
KEY_PASSWORD=changeit
```

## Common Debugging

```bash
# mTLS handshake failures — verify cert chain
openssl verify -CAfile certs/ca/ca.crt certs/client/client.crt
openssl s_client -connect localhost:9093 -cert certs/client/client.crt \
  -key certs/client/client.key -CAfile certs/ca/ca.crt

# KRaft controller stuck — check logs
kubectl logs -n confluent kraftcontroller-0
kubectl describe kraftcontroller kraftcontroller -n confluent

# Re-generate certs after expiry
CERT_VALIDITY_DAYS=365 ./confluent/mtls/generate-certs.sh
./confluent/mtls/create-k8s-secrets.sh
kubectl rollout restart statefulset/kafka statefulset/kraftcontroller -n confluent
```
