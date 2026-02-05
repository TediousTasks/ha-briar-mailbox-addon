ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base-debian:latest

# -------- Build stage --------
FROM ${BUILD_FROM} AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash git unzip ca-certificates openjdk-17-jdk \
  && update-ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone --depth=1 https://code.briarproject.org/briar/briar-mailbox.git .

RUN ./gradlew --no-daemon x86LinuxJar \
 && test -f mailbox-cli/build/libs/mailbox-cli-linux-x86_64.jar \
 && mkdir -p /out \
 && cp mailbox-cli/build/libs/mailbox-cli-linux-x86_64.jar /out/briar-mailbox.jar

# -------- Runtime stage --------
FROM ${BUILD_FROM}

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates openjdk-17-jre-headless \
  && update-ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/briar-mailbox.jar /app/briar-mailbox.jar
COPY run.sh /run.sh
RUN chmod a+x /run.sh

WORKDIR /data
CMD [ "/run.sh" ]
