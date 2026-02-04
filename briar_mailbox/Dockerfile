ARG BUILD_FROM

# ---------- Build stage ----------
FROM openjdk:17-jdk-slim AS builder
WORKDIR /build

RUN apt-get update && apt-get install -y git

RUN git clone https://code.briarproject.org/briar/briar-mailbox.git .
RUN ./gradlew x86LinuxJar

# ---------- Runtime stage ----------
FROM $BUILD_FROM

RUN apk add --no-cache openjdk17-jre ca-certificates \
  && update-ca-certificates

WORKDIR /data

COPY --from=builder /build/build/libs/*x86_64*.jar /app/briar-mailbox.jar
COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD ["/run.sh"]
