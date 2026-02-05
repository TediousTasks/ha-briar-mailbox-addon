ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:latest

# -------- Build stage (compile fat JAR) --------
FROM ${BUILD_FROM} AS builder

RUN apk add --no-cache \
    bash \
    git \
    openjdk17-jdk \
    unzip \
    ca-certificates \
  && update-ca-certificates

WORKDIR /build

RUN git clone --depth=1 https://code.briarproject.org/briar/briar-mailbox.git . \
  && ./gradlew --no-daemon x86LinuxJar \
  && test -f mailbox-cli/build/libs/mailbox-cli-linux-x86_64.jar \
  && mkdir -p /out \
  && cp mailbox-cli/build/libs/mailbox-cli-linux-x86_64.jar /out/briar-mailbox.jar

# -------- Runtime stage --------
FROM ${BUILD_FROM}

RUN apk add --no-cache \
    bash \
    openjdk17-jre \
    ca-certificates \
  && update-ca-certificates

#Copy from /out (created in builder stage)
COPY --from=builder /out/briar-mailbox.jar /app/briar-mailbox.jar

COPY run.sh /run.sh
RUN chmod a+x /run.sh

WORKDIR /data
CMD [ "/run.sh" ]
