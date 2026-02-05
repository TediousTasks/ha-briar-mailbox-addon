# Give a safe default so BUILD_FROM is never blank during parsing/linting
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base-debian:latest

# -------- Build stage (compile fat JAR) --------
FROM ${BUILD_FROM} AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash git unzip ca-certificates \
    default-jdk \
  && update-ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN git clone --depth=1 https://code.briarproject.org/briar/briar-mailbox.git . \
  && ./gradlew --no-daemon x86LinuxJar

# -------- Runtime stage --------
FROM ${BUILD_FROM}

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates \
    default-jre-headless \
  && update-ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Jar path confirmed by your build output
COPY --from=builder /build/mailbox-cli/build/libs/mailbox-cli-linux-x86_64.jar /app/briar-mailbox.jar

COPY run.sh /run.sh
RUN chmod a+x /run.sh

WORKDIR /data
CMD [ "/run.sh" ]
