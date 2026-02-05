#!/usr/bin/with-contenv bash
# HA add-on run script with:
# - Ingress UI on :8080 serving /data
# - PAIRING vs CONNECTED detection
# - Persistent connected flag (/data/connected)
# - Reset button (POST /reset) that wipes Briar state + restarts Briar
# - Log tail visible in UI (/data/briar_tail.txt)
#
# IMPORTANT FIX:
# Your previous script *did* start Briar, but you never saw "Starting Briar mailbox..."
# because it was printed inside a command-substitution (BriarPID="$(start_briar)"),
# which captures stdout. This version logs to STDERR and does NOT use command-substitution.

set -uo pipefail

DATA_DIR="/data"
LOG="/tmp/briar.log"
HTTP_LOG="/tmp/http.log"

INDEX="${DATA_DIR}/index.html"
QR_TXT="${DATA_DIR}/mailbox.txt"
QR_ASCII="${DATA_DIR}/qr_ascii.txt"
STATUS_TXT="${DATA_DIR}/status.txt"
BRIAR_TAIL="${DATA_DIR}/briar_tail.txt"

CONNECTED_FLAG="${DATA_DIR}/connected"
RESET_FLAG="${DATA_DIR}/reset"

mkdir -p "$DATA_DIR"
mkdir -p /data/.local/share /data/.config /data/.cache

# Force Briar to use /data (not /root)
export HOME=/data
export XDG_DATA_HOME=/data/.local/share
export XDG_CONFIG_HOME=/data/.config
export XDG_CACHE_HOME=/data/.cache

# Ensure files exist
: > "$LOG"
: > "$QR_TXT"
: > "$QR_ASCII"
: > "$BRIAR_TAIL"
echo "STARTING" > "$STATUS_TXT"

# Log to STDERR so it always shows in HA logs even when stdout is captured anywhere
log() { echo "[$(date -Is)] $*" >&2; }

update_briar_tail() {
  tail -n 200 "$LOG" > "$BRIAR_TAIL" 2>/dev/null || true
}

mark_connected() {
  date -Is > "$CONNECTED_FLAG"
  echo "CONNECTED" > "$STATUS_TXT"
  : > "$QR_TXT"
  : > "$QR_ASCII"
  update_briar_tail
}

mark_pairing() {
  rm -f "$CONNECTED_FLAG" 2>/dev/null || true
  echo "PAIRING" > "$STATUS_TXT"
  update_briar_tail
}

do_reset_now() {
  log "RESET requested — wiping Briar state to force re-pairing..."
  echo "RESETTING" > "$STATUS_TXT"

  rm -f "$CONNECTED_FLAG" 2>/dev/null || true
  : > "$QR_TXT"
  : > "$QR_ASCII"

  # Wipe Briar state (because HOME/XDG_* point to /data)
  rm -rf /data/.local/share/* /data/.config/* /data/.cache/* 2>/dev/null || true

  rm -f "$RESET_FLAG" 2>/dev/null || true

  : > "$LOG"
  update_briar_tail
  log "RESET complete."
}

# --- Generate UI (relative paths only for ingress) ---
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
    .wrap { max-width: 900px; margin: 0 auto; }
    .muted { color:#666; }
    .card { border:1px solid #ddd; border-radius:12px; padding:16px; background:#fff; }
    pre { white-space: pre; overflow-x:auto; background:#f7f7f7; border:1px solid #ddd; border-radius:8px; padding:12px; }
    code { word-break: break-all; display:block; padding:12px; border:1px solid #ccc; border-radius:8px; background:#f7f7f7; }
    .ok { display:inline-block; padding:6px 10px; border-radius:999px; background:#e9f7ef; border:1px solid #bfe8cf; }
    .warn { display:inline-block; padding:6px 10px; border-radius:999px; background:#fff6e5; border:1px solid #ffe0a3; }
    .btn { display:inline-block; padding:10px 12px; border:1px solid #ccc; border-radius:10px; background:#f7f7f7; text-decoration:none; color:#000; cursor:pointer; }
    .btn-danger { border-color:#f1b0b7; background:#fff0f2; }
    .row { display:flex; gap:10px; flex-wrap:wrap; align-items:center; }
    h3 { margin-top: 18px; }
  </style>
</head>
<body>
  <div class="wrap">
    <h2>Briar Mailbox</h2>
    <p class="muted">No auto-refresh. Click Refresh while pairing. Reset forces a new pairing.</p>

    <div class="card">
      <div class="row">
        <div id="stateTag" class="warn">Loading…</div>
        <a class="btn" href="./">Refresh</a>
        <button class="btn btn-danger" id="resetBtn" type="button">Reset mailbox (force re-pair)</button>
      </div>

      <div id="connectedBlock" style="display:none; margin-top:12px;">
        <h3>Connected</h3>
        <p class="muted">Mailbox is configured. Pairing details are hidden.</p>
      </div>

      <div id="pairBlock" style="display:none; margin-top:12px;">
        <h3>Pairing</h3>
        <p class="muted">Scan the ASCII QR in Briar Android, or copy the desktop link.</p>

        <h4>ASCII QR</h4>
        <pre id="ascii">(waiting...)</pre>

        <h4>Desktop link</h4>
        <code id="link">(waiting...)</code>
      </div>

      <h3>Runtime log (last 200 lines)</h3>
      <pre id="logtail">(loading...)</pre>
    </div>

    <script>
      async function loadText(path) {
        const r = await fetch(path, { cache: 'no-store' });
        if (!r.ok) throw new Error(path + " " + r.status);
        return (await r.text());
      }

      async function refreshUI() {
        let status = "STARTING";
        try { status = (await loadText("status.txt")).trim(); } catch {}

        const stateTag = document.getElementById("stateTag");
        const connectedBlock = document.getElementById("connectedBlock");
        const pairBlock = document.getElementById("pairBlock");

        const s = (status || "").toUpperCase();
        const isConnected = s.startsWith("CONNECTED");
        const isPairing   = s.startsWith("PAIRING");
        const isResetting = s.startsWith("RESETTING");

        if (isConnected) {
          stateTag.className = "ok";
          stateTag.textContent = "CONNECTED";
          connectedBlock.style.display = "block";
          pairBlock.style.display = "none";
        } else {
          stateTag.className = "warn";
          stateTag.textContent = isResetting ? "RESETTING" : (isPairing ? "PAIRING" : (status || "STARTING"));
          connectedBlock.style.display = "none";
          pairBlock.style.display = isPairing ? "block" : "none";
        }

        if (isPairing) {
          try { document.getElementById("link").textContent = (await loadText("mailbox.txt")).trim() || "(waiting...)"; }
          catch { document.getElementById("link").textContent = "(error loading mailbox.txt)"; }

          try { document.getElementById("ascii").textContent = (await loadText("qr_ascii.txt")).trim() || "(waiting...)"; }
          catch { document.getElementById("ascii").textContent = "(error loading qr_ascii.txt)"; }
        }

        try { document.getElementById("logtail").textContent = (await loadText("briar_tail.txt")).trim() || "(empty)"; }
        catch { document.getElementById("logtail").textContent = "(error loading briar_tail.txt)"; }
      }

      document.getElementById("resetBtn").addEventListener("click", async () => {
        if (!confirm("Reset mailbox now? This will require pairing again.")) return;
        try {
          const r = await fetch("reset", { method: "POST", cache: "no-store" });
          if (!r.ok) throw new Error("HTTP " + r.status);
          await new Promise(res => setTimeout(res, 800));
          location.reload();
        } catch (e) {
          alert("Reset failed: " + e);
        }
      });

      refreshUI();
    </script>
  </div>
</body>
</html>
HTML

# --- Python web server: serves /data + POST /reset creates /data/reset ---
cat > /tmp/server.py <<'PY'
from http.server import SimpleHTTPRequestHandler, HTTPServer
import os

DATA_DIR = "/data"
RESET_FLAG = os.path.join(DATA_DIR, "reset")

class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/" or self.path.startswith("/?"):
            self.path = "/index.html"
        return super().do_GET()

    def do_POST(self):
        if self.path.rstrip("/") == "/reset":
            try:
                with open(RESET_FLAG, "w", encoding="utf-8") as f:
                    f.write("reset\n")
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.end_headers()
                self.wfile.write(b"OK\n")
            except Exception as e:
                self.send_response(500)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.end_headers()
                self.wfile.write(("ERROR: %s\n" % e).encode("utf-8"))
            return
        self.send_response(404)
        self.end_headers()

os.chdir(DATA_DIR)
HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY

python /tmp/server.py >"$HTTP_LOG" 2>&1 &
log "HTTP server started on :8080. Logs: $HTTP_LOG"

# --- Briar parsing helpers ---
extract_ascii_qr() {
  awk '
    BEGIN {inside=0}
    /Please scan this with the Briar Android app:/ {inside=1; next}
    /Or copy and paste this into Briar Desktop:/ {inside=0}
    inside==1 {print}
  ' "$LOG" > "$QR_ASCII" 2>/dev/null || true

  python - <<'PY'
from pathlib import Path
p = Path("/data/qr_ascii.txt")
try:
    lines = p.read_text(encoding="utf-8", errors="ignore").splitlines()
except FileNotFoundError:
    lines = []
while lines and not lines[0].strip():
    lines.pop(0)
while lines and not lines[-1].strip():
    lines.pop()
p.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
PY
}

update_pairing_url() {
  local url=""
  url="$(grep -Eo 'briar-mailbox://[^[:space:]]+' "$LOG" 2>/dev/null | tail -n 1 || true)"
  if [[ -n "$url" ]]; then
    echo "$url" > "$QR_TXT"
  fi
}

saw_pairing_prompt() {
  grep -q "Please scan this with the Briar Android app:" "$LOG" 2>/dev/null \
  || grep -q "Or copy and paste this into Briar Desktop:" "$LOG" 2>/dev/null \
  || grep -Eqo 'briar-mailbox://[^[:space:]]+' "$LOG" 2>/dev/null
}

tor_bootstrapped() {
  grep -q "Bootstrapped 100% (done): Done" "$LOG" 2>/dev/null
}

# Start Briar and set global BriarPID (no stdout capture tricks)
BriarPID=""

start_briar() {
  : > "$LOG"
  update_briar_tail
  log "Starting Briar mailbox..."
  echo "STARTING (launching Briar)" > "$STATUS_TXT"

  # If java/jar is broken, we want to SEE it and not exit the whole script.
  set +e
  java -jar /app/briar-mailbox.jar 2>&1 | tee -a "$LOG" &
  BriarPID="$!"
  set -e

  log "Briar PID: $BriarPID"
  update_briar_tail
}

# --- Main supervisor loop (keeps script alive in foreground) ---
while true; do
  # Make initial state visible quickly
  if [[ -f "$CONNECTED_FLAG" ]]; then
    echo "CONNECTED (flag)" > "$STATUS_TXT"
  else
    echo "STARTING" > "$STATUS_TXT"
  fi

  start_briar

  # Decide CONNECTED vs PAIRING within 60s, while honoring RESET at any time.
  decided="no"
  for _ in $(seq 1 60); do
    if [[ -f "$RESET_FLAG" ]]; then
      log "Reset flag detected during startup window."
      kill "$BriarPID" 2>/dev/null || true
      wait "$BriarPID" 2>/dev/null || true
      do_reset_now
      decided="reset"
      break
    fi

    if ! kill -0 "$BriarPID" 2>/dev/null; then
      echo "ERROR: Briar exited" > "$STATUS_TXT"
      update_briar_tail
      decided="dead"
      break
    fi

    if saw_pairing_prompt; then
      mark_pairing
      update_pairing_url
      extract_ascii_qr
      update_briar_tail
      decided="pairing"
      break
    fi

    if tor_bootstrapped; then
      mark_connected
      update_briar_tail
      decided="connected"
      break
    fi

    update_briar_tail
    sleep 1
  done

  # If reset happened, restart outer loop
  if [[ "$decided" == "reset" ]]; then
    sleep 1
    continue
  fi

  # If Briar died, restart outer loop
  if [[ "$decided" == "dead" ]]; then
    sleep 2
    continue
  fi

  # If in PAIRING, keep updating until CONNECTED (or reset) or Briar exits
  if grep -q "^PAIRING" "$STATUS_TXT" 2>/dev/null; then
    stable_connected=0
    while kill -0 "$BriarPID" 2>/dev/null; do
      if [[ -f "$RESET_FLAG" ]]; then
        log "Reset flag detected during pairing."
        kill "$BriarPID" 2>/dev/null || true
        wait "$BriarPID" 2>/dev/null || true
        do_reset_now
        stable_connected=0
        break
      fi

      update_pairing_url
      extract_ascii_qr

      if ! saw_pairing_prompt && tor_bootstrapped; then
        stable_connected=$((stable_connected + 1))
      else
        stable_connected=0
      fi

      if [[ "$stable_connected" -ge 10 ]]; then
        mark_connected
        log "Detected connected state. Pairing details cleared."
        break
      fi

      update_briar_tail
      sleep 1
    done

    # If we reset in pairing, restart outer loop
    if [[ -f "$RESET_FLAG" ]]; then
      rm -f "$RESET_FLAG" 2>/dev/null || true
      sleep 1
      continue
    fi
  fi

  # Steady-state: keep Briar alive, allow reset, update log tail
  while true; do
    if [[ -f "$RESET_FLAG" ]]; then
      log "Reset flag detected during steady-state."
      kill "$BriarPID" 2>/dev/null || true
      wait "$BriarPID" 2>/dev/null || true
      do_reset_now
      break
    fi

    if ! kill -0 "$BriarPID" 2>/dev/null; then
      log "Briar exited unexpectedly; restarting..."
      echo "ERROR: Briar exited" > "$STATUS_TXT"
      update_briar_tail
      break
    fi

    update_briar_tail
    sleep 2
  done

  sleep 2
done
