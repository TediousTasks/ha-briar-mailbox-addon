#!/usr/bin/with-contenv bash
set -euo pipefail

export HOME="/data"
export XDG_DATA_HOME="/data/xdg/data"
export XDG_CONFIG_HOME="/data/xdg/config"
export XDG_CACHE_HOME="/data/xdg/cache"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

exec java -jar /app/briar-mailbox.jar
