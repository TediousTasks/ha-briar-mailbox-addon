#!/usr/bin/with-contenv bashio
set -e

export HOME=/data
mkdir -p /data

exec java -jar /app/briar-mailbox.jar
