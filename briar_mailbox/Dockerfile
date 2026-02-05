# Home Assistant passes BUILD_FROM at build time, but we give a safe default
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:latest

# -------------------------
# Build stage (compile JAR)
# -------------------------
FROM eclipse-temurin:17-jdk-jammy AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates unzip \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Clone and build
RUN git clone --depth=1 https://code.briarproject.org/briar/briar-mailbox.git . \
  && ./gradlew --no-daemon x86LinuxJar \
  && ls -la mailbox-cli/build/libs/

# Put the jar somewhere predictable
RUN cp mailbox-cli/build/libs/mailbox-cli-linux-x86_64.jar /out/briar-mailbox.jar


# -------------------------
# Runtime stage (HA base)
# -------------------------
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:latest
FROM ${BUILD_FROM}

# HA base is Alpine, so use apk
RUN apk add --no-cache \
    bash \
    openjdk17-jre \
    ca-certificates \
  && update-ca-certificates

COPY --from=builder /out/briar-mailbox.jar /app/briar-mailbox.jar
COPY run.sh /run.sh
RUN chmod a+x /run.sh

WORKDIR /data
CMD ["/run.sh"]
