ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base-debian:latest

# -------------------------
# Builder: compile JAR
# -------------------------
FROM eclipse-temurin:17-jdk-jammy AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates unzip \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN git clone --depth=1 https://code.briarproject.org/briar/briar-mailbox.git . \
  && ./gradlew --no-daemon x86LinuxJar \
  && mkdir -p /out \
  && cp mailbox-cli/build/libs/mailbox-cli-linux-x86_64.jar /out/briar-mailbox.jar

# -------------------------
# Runtime: HA base + Java17 (copied) + python3 for web server
# -------------------------
FROM ${BUILD_FROM}

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates \
    python3 \
  && update-ca-certificates \
  && rm -rf /var/lib/apt/lists/*

ENV HOME=/data
ENV XDG_DATA_HOME=/data/.local/share
ENV XDG_CONFIG_HOME=/data/.config
ENV XDG_CACHE_HOME=/data/.cache

COPY --from=builder /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="/opt/java/openjdk/bin:${PATH}"

COPY --from=builder /out/briar-mailbox.jar /app/briar-mailbox.jar
COPY run.sh /run.sh
RUN chmod a+x /run.sh

WORKDIR /data
CMD ["/run.sh"]
