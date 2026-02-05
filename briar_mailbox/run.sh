#!/usr/bin/with-contenv bash
set -euo pipefail

DATA_DIR="/data"
LOG="/tmp/briar.log"
INDEX="${DATA_DIR}/index.html"
QR_TXT="${DATA_DIR}/mailbox.txt"
QR_ASCII="${DATA_DIR}/qr_ascii.txt"
STATUS_TXT="${DATA_DIR}/status.txt"
CONNECTED_FLAG="${DATA_DIR}/connected"   # persists across restarts
RESET_FLAG="${DATA_DIR}/reset"           # create this file to force re-pairing
HTTP_LOG="/tmp/http.log"

mkdir -p "$DATA_DIR"
: > "$LOG"

# Force Briar to use /data (not /root)
export HOME=/data
export XDG_DATA_HOME=/data/.local/share
export XDG_CONFIG_HOME=/data/.config
export XDG_CACHE_HOME=/data/.cache
mkdir -p /data/.local/share /data/.config /data/.cache

# Reset option:
# Create /data/reset (empty file is fine), then restart the add-on.
# This will wipe Briar's persisted state under /data and force a new pairing QR/URL.
if [[ -f "$RESET_FLAG" ]]; then
  echo "RESET requested via $RESET_FLAG — wiping Briar state to force re-pairing..."

  # Clear UI state + pairing artifacts
  rm -f "$CONNECTED_FLAG" 2>/dev/null || true
  : > "$QR_TXT"
  : > "$QR_ASCII"
  echo "RESETTING" > "$STATUS_TXT"

  # Wipe Briar state (because HOME/XDG_* point to /data)
  rm -rf /data/.local/share/* /data/.config/* /data/.cache/* 2>/dev/null || true

  # Remove the reset flag so it only runs once
  rm -f "$RESET_FLAG" 2>/dev/null || true

  echo "RESET complete. Starting fresh..."
fi

# Placeholders so Ingress never 404s
: > "$QR_TXT"
: > "$QR_ASCII"
echo "STARTING" > "$STATUS_TXT"

mark_connected() {
  date -Is > "$CONNECTED_FLAG"
  echo "CONNECTED" > "$STATUS_TXT"
  # Hide pairing artifacts (defense-in-depth)
  : > "$QR_TXT"
  : > "$QR_ASCII"
}

mark_pairing() {
  rm -f "$CONNECTED_FLAG" 2>/dev/null || true
  echo "PAIRING" > "$STATUS_TXT"
}

# HTML (relative paths only — HA ingress)
cat > "$INDEX" <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>Briar Mailbox</title>
  <style>
    html, body { background:#fff; color:#000; margin:0; padding:0; }
    body { font-family: sans-serif; padding: 16px; }
    .wrap { max-width: 760px; margin: 0 auto; }
    .muted { color:#666; }
    .card { border:1px solid #ddd; border-radius:12px; padding:16px; background:#fff; }
    pre { white-space: pre; overflow-x:auto; background:#f7f7f7; border:1px solid #ddd; border-radius:8px; padding:12px; }
    code { word-break: break-all; display:block; padding:12px; border:1px solid #ccc; border-radius:8px; background:#f7f7f7; }
    .ok { display:inline-block; padding:6px 10px; border-radius:999px; background:#e9f7ef; border:1px solid #bfe8cf; }
    .warn { display:inline-block; padding:6px 10px; border-radius:999px; background:#fff6e5; border:1px solid #ffe0a3; }
    .btn { display:inline-block; margin-top:10px; padding:10px 12px; border:1px solid #ccc; border-radius:10px; background:#f7f7f7; text-decoration:none; color:#000; }
  </style>
</head>
<body>
  <div class="wrap">
    <h2>Briar Mailbox</h2>
    <p class="muted">This page does not auto-refresh. Use Refresh while pairing.</p>

    <div class="card">
      <div id="stateTag" class="warn">Loading…</div>

      <div id="connectedBlock" style="display:none; margin-top:12px;">
        <h3>Connected</h3>
        <p class="muted">This mailbox appears to already be configured. Pairing details are hidden.</p>
      </div>

      <div id="pairBlock" style="display:none; margin-top:12px;">
        <h3>Pairing</h3>
        <p class="muted">Scan the ASCII QR in the Briar Android app, or copy the desktop link.</p>

        <h4>ASCII QR</h4>
        <pre id="ascii">(waiting...)</pre>

        <h4>Desktop link</h4>
        <code id="link">(waiting...)</code>
      </div>

      <a class="btn" href="./">Refresh</a>
    </div>

    <script>
      async function loadText(path) {
        const r = await fetch(path, { cache: 'no-store' });
        if (!r.ok) throw new Error(path + " " + r.status);
        return (await r.text()).trim();
      }

      (async () => {
        let status = "STARTING";
        try { status = await loadText("status.txt"); } catch {}

        const stateTag = document.getElementById("stateTag");
        const connectedBlock = document.getElementById("connectedBlock");
        const pairBlock = document.getElementById("pairBlock");

        const s = (status || "").toUpperCase();
        const isConnected = s.startsWith("CONNECTED");
        const isPairing   = s.startsWith("PAIRING");

        if (isConnected) {
          stateTag.className = "ok";
          stateTag.textContent = "CONNECTED";
          connectedBlock.style.display = "block";
          pairBlock.style.display = "none";
          return;
        }

        stateTag.className = "warn";
        stateTag.textContent = isPairing ? "PAIRING" : (status || "STARTING");
        connectedBlock.style.display = "none";
        pairBlock.style.display = isPairing ? "block" : "none";

        if (isPairing) {
          try { document.getElementById("link").textContent = await loadText("mailbox.txt") || "(waiting...)"; }
          catch { document.getElementById("link").textContent = "(error loading mailbox.txt)"; }

          try { document.getElementById("ascii").textContent = await loadText("qr_ascii.txt") || "(waiting...)"; }
          catch { document.getElementById("ascii").textContent = "(error loading qr_ascii.txt)"; }
        }
      })();
    </script>
  </div>
</body>
</html>
HTML

# Serve /data on 8080 (Ingress-safe)
cat > /tmp/server.py <<'PY'
from http.server import SimpleHTTPRequestHandler, HTTPServer
import os

class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/" or self.path.startswith("/?"):
            self.path = "/index.html"
        return super().do_GET()

os.chdir("/data")
HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY

python /tmp/server.py >"$HTTP_LOG" 2>&1 &
echo "HTTP server started on :8080. Logs: $HTTP_LOG"

# Start Briar mailbox (log captured)
echo "Starting Briar mailbox..."
java -jar /app/briar-mailbox.jar 2>&1 | tee -a "$LOG" &
BriarPID=$!

extract_ascii_qr() {
  awk '
    BEGIN {inside=0}
    /Please scan this with the Briar Android app:/ {inside=1; next}
    /Or copy and paste this into Briar Desktop:/ {inside=0}
    inside==1 {print}
  ' "$LOG" > "$QR_ASCII" || true

  python - <<'PY'
from pathlib import Path
p = Path("/data/qr_ascii.txt")
lines = p.read_text(encoding="utf-8", errors="ignore").splitlines()
while lines and not lines[0].strip():
    lines.pop(0)
while lines and not lines[-1].strip():
    lines.pop()
p.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
PY
}

update_pairing_url() {
  local url
  url="$(grep -Eo 'briar-mailbox://[^[:space:]]+' "$LOG" | tail -n 1 || true)"
  if [[ -n "$url" ]]; then
    echo "$url" > "$QR_TXT"
  fi
}

saw_pairing_prompt() {
  grep -q "Please scan this with the Briar Android app:" "$LOG" \
  || grep -q "Or copy and paste this into Briar Desktop:" "$LOG" \
  || grep -Eqo 'briar-mailbox://[^[:space:]]+' "$LOG"
}

tor_bootstrapped() {
  # Your “already configured” logs reliably include this line:
  grep -q "Bootstrapped 100% (done): Done" "$LOG"
}

# Default UI state based on persisted flag
if [[ -f "$CONNECTED_FLAG" ]]; then
  echo "CONNECTED (flag)" > "$STATUS_TXT"
else
  echo "STARTING" > "$STATUS_TXT"
fi

# Wait up to ~60 seconds to decide state from logs
for i in $(seq 1 60); do
  if ! kill -0 "$BriarPID" 2>/dev/null; then
    echo "ERROR: Briar exited" > "$STATUS_TXT"
    break
  fi

  # If we ever see pairing prompts, we are NOT connected anymore (reset/re-pair case)
  if saw_pairing_prompt; then
    mark_pairing
    update_pairing_url
    extract_ascii_qr
    break
  fi

  # If Tor is bootstrapped and no pairing prompts, consider it connected
  if tor_bootstrapped; then
    mark_connected
    break
  fi

  sleep 1
done

# If we entered PAIRING, keep updating artifacts until it becomes connected
if grep -q "^PAIRING" "$STATUS_TXT"; then
  echo "Pairing mode: updating ASCII + URL..."
  stable_connected_count=0

  while true; do
    if ! kill -0 "$BriarPID" 2>/dev/null; then
      echo "ERROR: Briar exited" > "$STATUS_TXT"
      break
    fi

    update_pairing_url
    extract_ascii_qr

    # If pairing prompt is gone and Tor is fully up, assume paired/connected.
    if ! saw_pairing_prompt && tor_bootstrapped; then
      stable_connected_count=$((stable_connected_count + 1))
    else
      stable_connected_count=0
    fi

    # Require ~10 seconds of stable “no pairing prompt + tor up” to flip state.
    if [[ "$stable_connected_count" -ge 10 ]]; then
      mark_connected
      echo "Detected connected state. Pairing details cleared."
      break
    fi

    sleep 1
  done
fi

wait "$BriarPID"
