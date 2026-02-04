# Home Assistant provides BUILD_FROM automatically.
# Give it a safe default so buildkit doesn't warn when linting/parsing.
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

# Clone upstream source
RUN git clone --depth=1 https://code.briarproject.org/briar/briar-mailbox.git .

# Build the x86_64 Linux fat JAR
RUN ./gradlew --no-daemon x86LinuxJar

# -------- Runtime stage --------
FROM ${BUILD_FROM}

RUN apk add --no-cache \
    bash \
    openjdk17-jre \
    ca-certificates \
  && update-ca-certificates

COPY --from=builder /build/build/libs/*x86_64*.jar /app/briar-mailbox.jar
COPY run.sh /run.sh
RUN chmod a+x /run.sh

WORKDIR /data
CMD [ "/run.sh" ]
