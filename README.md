# OMB Confluent mTLS

A complete, production-ready Docker-based multi-worker **Open Messaging Benchmark (OMB)** platform for load-testing an **mTLS-enabled K3D-based Confluent Platform cluster** using **CFK (Confluent for Kubernetes) in pure KRaft mode**.

> **No ZooKeeper.** This is a pure KRaft deployment using CFK's `KRaftController` and `Kafka` custom resources.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         K3D Cluster                                  │
│               (k3d-confluent-benchmark Docker network)               │
│                                                                      │
│  ┌──────────────────────┐    ┌──────────────────────────────────┐   │
│  │   KRaftController    │    │         Kafka Brokers            │   │
│  │    (3 replicas)      │◄───│          (3 replicas)            │   │
│  │                      │    │                                  │   │
│  │  Raft quorum over    │    │  spec.dependencies.kRaftControl  │   │
│  │  mTLS (no ZooKeeper) │    │  ler → kraftcontroller           │   │
│  │                      │    │                                  │   │
│  │  Port: Raft/internal │    │  Internal listener: mTLS         │   │
│  └──────────────────────┘    │  External listener: mTLS         │   │
│                               │  NodePorts: 30093/30094/30095   │   │
│                               └──────────┬───────────────────────┘   │
│                                          │ K3D LoadBalancer           │
└──────────────────────────────────────────┼─────────────────────────── ┘
                                           │ mTLS
                          host ports 9093 / 9094 / 9095
                                           │
┌──────────────────────────────────────────┼─────────────────────────── ┐
│  Docker Compose (OMB)  [host network]    │                             │
│                                          │ JKS client certs            │
│  ┌────────────┐  ┌────────────┐  ┌──────┴─────┐  ┌────────────────┐  │
│  │ omb-worker │  │ omb-worker │  │ omb-worker │  │   omb-driver   │  │
│  │    :8080   │  │    :8081   │  │    :8082   │  │ (orchestrates) │  │
│  └────────────┘  └────────────┘  └────────────┘  └────────────────┘  │
│         All containers mount certs/ with client.keystore.jks           │
└─────────────────────────────────────────────────────────────────────── ┘
```

**Key design decisions:**

| Component | Choice | Reason |
|-----------|--------|--------|
| Metadata quorum | **KRaft** (`KRaftController` CR) | No ZooKeeper dependency |
| TLS | **mTLS end-to-end** | CA → controllers → brokers → clients |
| Cluster | **K3D** (Docker-based K8s) | Runs on a laptop |
| Operator | **CFK** (Confluent for Kubernetes) | Manages Kafka lifecycle |
| Benchmarking | **OMB** (Open Messaging Benchmark) | Industry-standard load testing |

---

## Prerequisites

| Tool | Minimum version | Install |
|------|----------------|---------|
| Docker | 24.x | https://docs.docker.com/get-docker/ |
| k3d | 5.6.x | `brew install k3d` / https://k3d.io |
| kubectl | 1.28+ | https://kubernetes.io/docs/tasks/tools/ |
| Helm | 3.14+ | https://helm.sh/docs/intro/install/ |
| OpenSSL | 3.x | Usually pre-installed |
| Java keytool | 17+ | Included with JDK |

---

## Quick Start

### 1. Clone and enter the repository

```bash
git clone https://github.com/simonjday/omb-confluent-mtls.git
cd omb-confluent-mtls
```

### 2. Run full setup (one command)

```bash
./scripts/setup-all.sh
```

This will:
1. Create a K3D cluster (`confluent-benchmark`) with 1 server + 3 agents
2. Install the CFK operator via Helm
3. Generate mTLS certificates (CA, broker, controller, client)
4. Create Kubernetes secrets
5. Deploy `KRaftController` (3 replicas) and `Kafka` (3 brokers)
6. Build OMB Docker images

Or run each step manually:

```bash
# 1. K3D cluster + CFK operator
./k3d/setup-k3d.sh

# 2. Generate certificates
./confluent/mtls/generate-certs.sh

# 3. Create K8s secrets
./confluent/mtls/create-k8s-secrets.sh

# 4. Deploy Confluent Platform (KRaft)
kubectl apply -f confluent/namespace.yaml
kubectl apply -f confluent/confluent-platform.yaml

# 5. Watch pods come up
kubectl get pods -n confluent -w

# 6. Build OMB images
./scripts/build-omb-images.sh
```

### 3. Run a benchmark

```bash
# Smoke test (1 topic, 1000 msg/s, 2 min)
./scripts/run-benchmark.sh simple-workload

# High-throughput (4 topics, 100k msg/s, 5 min)
./scripts/run-benchmark.sh high-throughput

# Low-latency (512B messages, 500 msg/s, 5 min)
./scripts/run-benchmark.sh low-latency

# Endurance (30-minute stability test)
./scripts/run-benchmark.sh endurance
```

### 4. View results

```bash
# Latest results
./scripts/collect-results.sh

# Specific file
./scripts/collect-results.sh results/high-throughput_20240101_120000.json
```

### 5. Teardown

```bash
./scripts/teardown.sh              # Stop containers + delete cluster
./scripts/teardown.sh --all        # Also remove certs/ and results/
```

---

## Configuration Reference

### Environment variables (`.env` file)

Create a `.env` file in the repo root (it's gitignored):

```bash
KAFKA_BOOTSTRAP_SERVERS=localhost:9093,localhost:9094,localhost:9095
KEYSTORE_PASSWORD=changeit
TRUSTSTORE_PASSWORD=changeit
KEY_PASSWORD=changeit
```

### TLS certificate passwords

| Variable | Default | Description |
|----------|---------|-------------|
| `KEYSTORE_PASSWORD` | `changeit` | JKS keystore password |
| `TRUSTSTORE_PASSWORD` | `changeit` | JKS truststore password |
| `KEY_PASSWORD` | `changeit` | Private key password |
| `CERT_VALIDITY_DAYS` | `3650` | Certificate validity (days) |

### Kafka bootstrap servers

The K3D cluster exposes Kafka brokers on host ports:

| Broker | Host port | K8s NodePort |
|--------|-----------|--------------|
| kafka-0 | 9093 | 30093 |
| kafka-1 | 9094 | 30094 |
| kafka-2 | 9095 | 30095 |

---

## Workload Customisation

Workload files are in `omb/workloads/`. All fields are standard OMB workload parameters:

| Field | Description |
|-------|-------------|
| `topics` | Number of Kafka topics to create |
| `partitionsPerTopic` | Partitions per topic |
| `messageSize` | Message payload size in bytes |
| `producersPerTopic` | Producers per topic |
| `producerRate` | Target publish rate (msg/s) |
| `consumerPerSubscription` | Consumers per subscription |
| `warmupDurationMinutes` | Warm-up period (excluded from results) |
| `testDurationMinutes` | Test duration |

Example custom workload:

```yaml
name: my-custom-workload
topics: 2
partitionsPerTopic: 8
messageSize: 4096
producersPerTopic: 4
producerRate: 5000
subscriptionsPerTopic: 1
consumerPerSubscription: 4
consumerBacklogSizeGB: 0
warmupDurationMinutes: 2
testDurationMinutes: 10
```

---

## Worker Scaling

The default configuration runs **3 OMB workers** (ports 8080–8082). To add more:

1. Add a new service to `docker/docker-compose.yml`:

```yaml
omb-worker-4:
  image: omb-worker:latest
  container_name: omb-worker-4
  network_mode: host
  volumes:
    - ../certs:/certs:ro
  command: ["bin/benchmark-worker", "--port", "8083"]
```

2. Add the new worker to `omb/workers.yaml`:

```yaml
workers:
  - http://localhost:8080
  - http://localhost:8081
  - http://localhost:8082
  - http://localhost:8083
```

---

## Troubleshooting

### mTLS issues

**Symptom:** `SSL handshake failed` or `UNKNOWN_CA`

```bash
# Verify the client certificate is signed by the CA
openssl verify -CAfile certs/ca/ca.crt certs/client/client.crt

# Inspect the broker certificate SANs
openssl x509 -noout -text -in certs/broker/broker.crt | grep -A5 "Subject Alternative Name"

# Test connectivity with openssl
openssl s_client -connect localhost:9093 \
  -cert certs/client/client.crt \
  -key certs/client/client.key \
  -CAfile certs/ca/ca.crt
```

**Solution:** Re-run `./confluent/mtls/generate-certs.sh` and `./confluent/mtls/create-k8s-secrets.sh`.

---

### KRaft issues

**Symptom:** `kraftcontroller` pods stuck in `Pending` or `CrashLoopBackOff`

```bash
# Check controller pod logs
kubectl logs -n confluent kraftcontroller-0

# Check CFK operator logs
kubectl logs -n confluent deployment/confluent-operator

# Describe the KRaftController CR
kubectl describe kraftcontroller kraftcontroller -n confluent
```

**Common causes:**
- `kraftcontroller-tls` secret missing → re-run `create-k8s-secrets.sh`
- Insufficient memory on K3D node → increase Docker Desktop memory limit
- `local-path` storage class not available → check `kubectl get sc`

---

### Connectivity issues

**Symptom:** OMB workers can't reach Kafka

```bash
# Check K3D port mappings are working
kubectl get svc -n confluent
curl -v --insecure https://localhost:9093

# Check K3D LoadBalancer container is running
docker ps | grep k3d

# Check Kafka external service NodePorts
kubectl get svc kafka-external -n confluent
```

**Symptom:** OMB workers can't communicate with each other

The workers use `network_mode: host`, so they must be on the same physical host.

---

### Certificate expiry

Certificates are valid for 3650 days (10 years) by default. To regenerate:

```bash
CERT_VALIDITY_DAYS=365 ./confluent/mtls/generate-certs.sh
./confluent/mtls/create-k8s-secrets.sh
# Restart Kafka pods to pick up new certs
kubectl rollout restart statefulset/kafka -n confluent
kubectl rollout restart statefulset/kraftcontroller -n confluent
```

---

## Results Interpretation

OMB results are JSON files in `results/`. Key metrics:

| Metric | Field | Description |
|--------|-------|-------------|
| Publish throughput | `publishRate` | Messages/second published |
| Publish latency p99 | `aggregatedPublishLatency99pct` | 99th percentile publish latency (ms) |
| E2E latency p99 | `aggregatedEndToEndLatency99pct` | 99th percentile end-to-end latency (ms) |
| E2E latency max | `aggregatedEndToEndLatencyMax` | Maximum end-to-end latency (ms) |

Use `./scripts/collect-results.sh` for a formatted summary, or process with `jq`:

```bash
jq '{
  throughput: .publishRate,
  p99_publish_ms: .aggregatedPublishLatency99pct,
  p99_e2e_ms: .aggregatedEndToEndLatency99pct,
  max_e2e_ms: .aggregatedEndToEndLatencyMax
}' results/*.json
```

---

## Directory Structure

```
omb-confluent-mtls/
├── .gitignore                    # Excludes certs/, results/, .env
├── README.md                     # This file
│
├── docker/
│   ├── Dockerfile.omb-worker     # OMB worker image (port 8080+)
│   ├── Dockerfile.omb-driver     # OMB driver image
│   └── docker-compose.yml        # 3 workers + 1 driver
│
├── k3d/
│   ├── k3d-cluster-config.yaml  # K3D cluster (1 server, 3 agents)
│   └── setup-k3d.sh             # Creates cluster + installs CFK
│
├── confluent/
│   ├── namespace.yaml            # 'confluent' namespace
│   ├── confluent-operator.yaml   # CFK Helm values
│   ├── confluent-platform.yaml   # KRaftController + Kafka CRs
│   └── mtls/
│       ├── openssl.cnf           # OpenSSL config with SANs
│       ├── generate-certs.sh     # Generates all certs + JKS stores
│       └── create-k8s-secrets.sh # Creates K8s secrets from certs
│
├── omb/
│   ├── driver-kafka.yaml         # Kafka driver with mTLS config
│   ├── workers.yaml              # Worker endpoints
│   └── workloads/
│       ├── simple-workload.yaml  # Smoke test (1k msg/s, 2 min)
│       ├── high-throughput.yaml  # 100k msg/s, 4 topics, 5 min
│       ├── low-latency.yaml      # 500 msg/s, 512B, 5 min
│       └── endurance.yaml        # 10k msg/s, 30 min
│
├── scripts/
│   ├── setup-all.sh             # Full end-to-end setup
│   ├── run-benchmark.sh         # Start workers + run workload
│   ├── build-omb-images.sh      # Build Docker images
│   ├── teardown.sh              # Stop + delete everything
│   └── collect-results.sh       # Print results summary
│
├── certs/                        # Generated certs (gitignored)
└── results/                      # Benchmark results (gitignored)
```

---

## Cleanup

```bash
# Stop containers and delete K3D cluster (keep certs and results)
./scripts/teardown.sh

# Full cleanup including certs and results
./scripts/teardown.sh --all
```
