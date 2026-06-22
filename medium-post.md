# Benchmark Confluent Kafka with mTLS on K3D — Fully Automated, Laptop-Friendly

> A step-by-step guide to spinning up a production-grade mTLS Kafka cluster in Docker, load-testing it with Open Messaging Benchmark, and tearing it all down again with a single command.

---

## Why bother?

Mutual TLS (mTLS) is table-stakes security for any Kafka cluster that leaves a development laptop. Every client must present a valid certificate; the broker verifies it before a single message is exchanged. Getting this right requires a functioning CA, correctly-signed broker and client certificates, JKS keystores, and a Kafka configuration that ties it all together.

The problem: setting all of that up manually takes hours, and doing it repeatably for benchmarking takes even longer. Every time you want to test a configuration change, you rebuild the cluster from scratch. This repository automates the entire pipeline so you can go from zero to running benchmarks in under 15 minutes.

---

## What the repo does

The repository provides a fully automated end-to-end benchmark platform:

- **K3D cluster** — A local Kubernetes cluster that runs entirely inside Docker — no VMs, no cloud costs. Three agent nodes, one per Kafka broker.
- **Confluent Platform (KRaft)** — Three Kafka brokers managed by the Confluent for Kubernetes (CFK) operator, running in pure KRaft mode — no ZooKeeper dependency.
- **mTLS everywhere** — A self-signed CA, broker certificates, controller certificates, and client certificates generated automatically. JKS keystores mounted into all containers.
- **Open Messaging Benchmark** — The industry-standard OMB tool, built into a single Docker image, run as three distributed workers plus a driver — all via Docker Compose.
- **Result analysis** — A Python script that reads OMB's JSON output and prints per-workload reports with latency histograms, throughput numbers, and pass/fail assessments.

---

## Architecture in 30 seconds

Everything runs inside Docker Desktop. The K3D cluster is a set of Docker containers acting as Kubernetes nodes. The Kafka brokers run as pods inside that cluster. The OMB workers run as separate Docker Compose containers with host networking, which means they share the Docker VM network and can reach the Kafka NodePort services directly.

```
Docker Desktop (VM)
  K3D cluster (Docker containers acting as K8s nodes)
    confluent namespace
      KRaftController x3  — Raft quorum, no ZooKeeper
      Kafka broker x3     — mTLS, NodePorts 9093-9096
  Docker Compose (host network)
    omb-worker-1  :8080
    omb-worker-2  :8082
    omb-worker-3  :8084
    omb-driver    (orchestrates workers)
```

---

## Who should use this?

- Platform engineers who want to measure Kafka performance characteristics before committing to a production cluster size.
- Security engineers validating that mTLS overhead is acceptable for their throughput and latency SLOs.
- Developers learning how Confluent for Kubernetes works, how KRaft replaces ZooKeeper, or how mTLS certificate chains are structured.
- Anyone who wants a disposable Kafka environment they can destroy and recreate in minutes.
- Teams evaluating different producer/consumer configurations (batch size, compression, replication factor) in a reproducible way.

---

## Quick start

Prerequisites: Docker Desktop, k3d, kubectl, helm, Java keytool. Then:

```bash
git clone https://github.com/simonjday/omb-confluent-mtls
cd omb-confluent-mtls
./scripts/setup-all.sh
```

That single command creates the K3D cluster, installs the CFK operator via Helm, generates all certificates, loads them into Kubernetes secrets, deploys the KRaftController and Kafka StatefulSets, waits for all pods to be ready, and builds the OMB Docker image. Go make a coffee.

Then run benchmarks:

```bash
./scripts/run-benchmark.sh simple-workload   # smoke test
./scripts/run-benchmark.sh low-latency       # p99 latency focus
./scripts/run-benchmark.sh high-throughput   # 100k msg/s
./scripts/run-benchmark.sh endurance         # 30-min stability
```

Review results:

```bash
python3 scripts/review-results.py
```

Tear everything down:

```bash
./scripts/teardown.sh       # stop containers + delete cluster
./scripts/teardown.sh --all # also remove certs and results
```

---

## What the results look like

The review script reads OMB's JSON output and produces a structured report for each workload. Below are results from a MacBook Pro with Docker Desktop configured with 24 GB RAM.

| Metric | Low-latency | High-throughput |
|---|---|---|
| Workload | 500 msg/s, 1 KB, 1 producer | 100k msg/s, 1 KB, 8 producers |
| Avg publish rate | 500 msg/s | 100,280 msg/s |
| Avg throughput | 0.48 MB/s | 97.93 MB/s |
| Pub latency p50 | 2.40 ms | 13.46 ms |
| Pub latency p99 | 11.02 ms | 133.31 ms |
| Pub latency p99.9 | 18.35 ms | 572.34 ms |
| E2E latency p50 | 3.00 ms | 14.00 ms |
| E2E latency p99 | 12.00 ms | 141.00 ms |
| Errors | 0 | 0 |
| Overall | PASS | PASS |

> Sub-3ms p50 end-to-end latency over mTLS in a containerised cluster on a laptop. The overhead of mutual TLS is real but well within acceptable bounds for most workloads.

---

## Connecting your own client

Once the cluster is running you can connect any Kafka client directly — not just OMB. The bootstrap servers are exposed on localhost at ports 9093, 9094, 9095, and 9096. All connections require mTLS: the client must present its certificate and trust the cluster CA.

After running `./confluent/mtls/generate-certs.sh`, the `certs/` directory contains everything you need:

```
certs/client/client.crt              # client certificate
certs/client/client.key              # client private key
certs/ca/ca.crt                      # CA certificate (trust anchor)
certs/client/client.keystore.jks     # JKS keystore (Java clients)
certs/client/client.truststore.jks   # JKS truststore (Java clients)
```

### Finding the topic name

OMB auto-generates topic names during a benchmark run — they are not `my-topic`. The generated names look like `test-xxxxxxxx-0` (a UUID prefix with a partition index). Before consuming, list the topics to find the right name.

```bash
# List all topics
kcat -b localhost:9093 \
  -X security.protocol=SSL \
  -X ssl.ca.location=certs/ca/ca.crt \
  -X ssl.certificate.location=certs/client/client.crt \
  -X ssl.key.location=certs/client/client.key \
  -L 2>/dev/null | grep "topic "
```

Or with the Kafka CLI:

```bash
kafka-topics.sh --bootstrap-server localhost:9093 \
  --command-config client.properties \
  --list
```

Pick the topic name from the output and substitute it into the consume commands below.

### kcat (kafkacat)

kcat is the fastest way to inspect topics and consume messages from the command line. Install with `brew install kcat` on macOS.

```bash
# Consume messages from a topic (replace <topic> with the name from the list above)
kcat -b localhost:9093 \
  -X security.protocol=SSL \
  -X ssl.ca.location=certs/ca/ca.crt \
  -X ssl.certificate.location=certs/client/client.crt \
  -X ssl.key.location=certs/client/client.key \
  -C -t <topic> -o beginning
```

### kafka-console-consumer / kafka-console-producer

If you have a Kafka distribution installed locally, create a `client.properties` file:

```properties
security.protocol=SSL
ssl.keystore.location=certs/client/client.keystore.jks
ssl.keystore.password=changeit
ssl.key.password=changeit
ssl.truststore.location=certs/client/client.truststore.jks
ssl.truststore.password=changeit
```

Then consume or produce:

```bash
# Replace <topic> with the name from the list above
kafka-console-consumer \
  --bootstrap-server localhost:9093 \
  --consumer.config client.properties \
  --topic <topic> --from-beginning

kafka-console-producer \
  --bootstrap-server localhost:9093 \
  --producer.config client.properties \
  --topic <topic>
```

### GUI tools

Kafkio, Offset Explorer (formerly Kafka Tool), and Conduktor all support custom SSL configuration. Point them at `localhost:9093`, set the security protocol to SSL, and provide the keystore and truststore paths from the `certs/client/` directory with password `changeit`.

---

## Benchmarking a remote Kafka cluster

The K3D cluster is the default target, but OMB is just a load generator — you can point it at any Kafka cluster. This makes the repo useful as a reusable benchmark harness against staging, on-prem, or cloud-hosted clusters too.

### What to skip

If you are targeting a remote cluster you do not need to set up K3D or Confluent Platform at all. Just build the OMB image and start the workers:

```bash
docker build -t omb:latest docker/
docker compose -f docker/docker-compose.yml up omb-worker-1 omb-worker-2 omb-worker-3 -d
```

### Update the driver config

Edit `omb/driver-kafka.yaml` and replace the `bootstrap.servers` and security settings to match your remote cluster.

**Remote cluster with mTLS:**

```yaml
commonConfig: |
  bootstrap.servers=your-broker-1:9093,your-broker-2:9093
  security.protocol=SSL
  ssl.keystore.location=/certs/client.keystore.jks
  ssl.keystore.password=your-password
  ssl.key.password=your-password
  ssl.truststore.location=/certs/client.truststore.jks
  ssl.truststore.password=your-password
```

Then update the volume mount in `docker/docker-compose.yml` to point at your keystores instead of the local `certs/` directory.

**Remote cluster with SASL/SSL (e.g. on-prem Confluent Platform with LDAP or SCRAM):**

```yaml
commonConfig: |
  bootstrap.servers=your-broker:9092
  security.protocol=SASL_SSL
  sasl.mechanism=SCRAM-SHA-512
  sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="user" password="pass";
  ssl.truststore.location=/certs/truststore.jks
  ssl.truststore.password=your-password
```

**Confluent Cloud:**

```yaml
commonConfig: |
  bootstrap.servers=pkc-xxxxx.region.provider.confluent.cloud:9092
  security.protocol=SASL_SSL
  sasl.mechanism=PLAIN
  sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="<API_KEY>" password="<API_SECRET>";
```

No certificate files needed for Confluent Cloud — it uses API key/secret over the public CA chain.

### Run the benchmark

Once the workers are up and the driver config is updated, run benchmarks exactly as normal:

```bash
./scripts/run-benchmark.sh high-throughput
python3 scripts/review-results.py
```

The results land in `results/` and the review script works the same way regardless of where the cluster lives.

---

## A few things worth knowing

### KRaft mode, no ZooKeeper

The cluster runs in pure KRaft mode using the KRaftController custom resource provided by CFK. There is no ZooKeeper ensemble, no ZooKeeper certificates, no ZooKeeper ports. The three KRaftController pods form a Raft quorum and manage all cluster metadata. This is how new Kafka deployments should be built.

### Certificate chain

The `generate-certs.sh` script creates a self-signed CA and uses it to sign separate certificates for the brokers, the controllers, and the OMB client. All certificates are stored in JKS format with a configurable password. The broker and controller certs are loaded into Kubernetes secrets; the client cert is mounted into the OMB containers as a volume.

### Port mapping trick

K3D's loadbalancer proxies each mapped port to K3D agent nodes on the same port number. This means Kafka's NodePort service values must match the K3D port mappings. The repository solves this by extending K3S's NodePort range to include ports 9093–9096 via a kube-apiserver arg, then setting CFK's `nodePortOffset` to 9093. Kafka advertises `localhost:9094`, `9095`, `9096` for individual brokers — addresses the OMB driver inside Docker can reach through the K3D loadbalancer.

### OMB worker memory

OMB's worker script defaults to `-Xms4G -Xmx4G`. With three workers that is 12 GB of committed heap before a single message is sent. The repository overrides `HEAP_OPTS` to `-Xms128m -Xmx1024m` per worker, which keeps RSS around 700 MB each and leaves plenty of headroom for the Kafka brokers and controllers running inside K3D.

---

## Try it

If you want a reproducible Kafka benchmark environment that works on any machine with Docker Desktop, does not require a cloud account, and comes with mTLS baked in from day one, this repository is a good starting point. Clone it, run setup, run a benchmark, review the results.

The repo is at [github.com/simonjday/omb-confluent-mtls](https://github.com/simonjday/omb-confluent-mtls).

---

*Tags: Kafka · Confluent · mTLS · Kubernetes · K3D · Benchmarking · Open Messaging Benchmark · KRaft · DevOps*
