# Dockerfile — Unified Open Messaging Benchmark image
# Supports both worker and driver modes via runtime command override.
#
# Worker mode:  docker run omb:latest
# Driver mode:  docker run omb:latest bin/benchmark --drivers ... --workers ...

FROM eclipse-temurin:17-jdk AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    maven \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN git clone https://github.com/openmessaging/benchmark.git . \
    && mvn clean install -DskipTests -T 4

# -------------------------------------------------------
# Runtime image
# -------------------------------------------------------
FROM eclipse-temurin:17-jdk

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/benchmark

COPY --from=builder /build/package/target/openmessaging-benchmark-0.0.1-SNAPSHOT-bin.tar.gz /tmp/omb.tar.gz

RUN tar -xzf /tmp/omb.tar.gz --strip-components=1 -C /opt/benchmark \
    && rm /tmp/omb.tar.gz

# Volume mount points for certs, workloads, and results
VOLUME ["/certs", "/workloads", "/results"]

# Worker HTTP port (used in worker mode)
EXPOSE 8080

# Default: start as worker on port 8080
# Override with docker-compose command/entrypoint for driver mode
CMD ["bin/benchmark-worker", "--port", "8080"]
