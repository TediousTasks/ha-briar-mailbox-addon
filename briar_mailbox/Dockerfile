# Home Assistant provides BUILD_FROM automatically.
# Safe default so it never becomes blank.
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base-debian:latest

# -------------------------
# Build stage (compile JAR)
# -------------------------
FROM eclipse-temurin:17-jdk-jammy AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates unzip \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN git clone --depth=1 https://code.briarproject.org/briar/briar-mailbox.git . \
  && ./gradlew --no-daemon x86LinuxJar \
  && cp mailbox-cli/build/libs/mailbox-cli-linux-x86_64.jar /out/briar-mailbox.jar

# -------------------------
# Runtime stage (HA Debian)
# -------------------------
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base-debian:latest
FROM ${BUILD_FROM}

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates \
    openjdk-17-jre-headless \
  && update-ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/briar-mailbox.jar /app/briar-mailbox.jar
COPY run.sh /run.sh
RUN chmod a+x /run.sh

WORKDIR /data
CMD ["/run.sh"]
