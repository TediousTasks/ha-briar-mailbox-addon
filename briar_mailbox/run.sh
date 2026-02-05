#!/usr/bin/with-contenv bash
set -e

# Make Briar use Home Assistant's persistent data directory
export HOME="/data"
export XDG_DATA_HOME="/data/xdg/data"
export XDG_CONFIG_HOME="/data/xdg/config"
export XDG_CACHE_HOME="/data/xdg/cache"

mkdir -p \
  "$XDG_DATA_HOME" \
  "$XDG_CONFIG_HOME" \
  "$XDG_CACHE_HOME"

echo "Starting Briar Mailbox…"
exec java -jar /app/briar-mailbox.jar
