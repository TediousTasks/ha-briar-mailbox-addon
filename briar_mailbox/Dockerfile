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

# Clone upstream source + build fat JAR
# Then locate the produced x86_64 jar without assuming a specific output path.
RUN git clone --depth=1 https://code.briarproject.org/briar/briar-mailbox.git . \
  && ./gradlew --no-daemon x86LinuxJar \
  && echo "=== JARs produced (debug) ===" \
  && find . -maxdepth 6 -type f -name "*.jar" -print \
  && JAR_PATH="$(find . -maxdepth 8 -type f -name '*x86_64*.jar' | head -n 1)" \
  && if [ -z "$JAR_PATH" ]; then \
       echo "ERROR: Could not find a '*x86_64*.jar' produced by Gradle."; \
       echo "Above is the jar list found. Adjust the find pattern if needed."; \
       exit 1; \
     fi \
  && mkdir -p /out \
  && cp "$JAR_PATH" /out/briar-mailbox.jar

# -------- Runtime stage --------
FROM ${BUILD_FROM}

RUN apk add --no-cache \
    bash \
    openjdk17-jre \
    ca-certificates \
  && update-ca-certificates

COPY --from=builder /out/briar-mailbox.jar /app/briar-mailbox.jar
COPY run.sh /run.sh
RUN chmod a+x /run.sh

WORKDIR /data
CMD [ "/run.sh" ]
