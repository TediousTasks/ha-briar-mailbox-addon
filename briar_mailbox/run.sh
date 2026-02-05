#!/usr/bin/with-contenv bash
set -u

DATA_DIR="/data"
LOG="/tmp/briar.log"
INDEX="${DATA_DIR}/index.html"
QR_TXT="${DATA_DIR}/mailbox.txt"
QR_ASCII="${DATA_DIR}/qr_ascii.txt"
STATUS_TXT="${DATA_DIR}/status.txt"
CONNECTED_FLAG="${DATA_DIR}/connected"
RESET_FLAG="${DATA_DIR}/reset"
HTTP_LOG="/tmp/http.log"

mkdir -p "$DATA_DIR"
: > "$LOG"

# Force Briar to use /data (not /root)
export HOME=/data
export XDG_DATA_HOME=/data/.local/share
export XDG_CONFIG_HOME=/data/.config
export XDG_CACHE_HOME=/data/.cache
mkdir -p /data/.local/share /data/.config /data/.cache

# Placeholders so Ingress never 404s
: > "$QR_TXT"
: > "$QR_ASCII"
echo "STARTING" > "$STATUS_TXT"

log() { echo "[$(date -Is)] $*"; }

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
  log "RESET complete."
}

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

# HTML (relative paths only — HA ingress) with Reset button
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
    .btn { display:inline-block; margin-top:10px; padding:10px 12px; border:1px solid #ccc; border-radius:10px; background:#f7f7f7; text-decoration:none; color:#000; cursor:pointer; }
    .btn-danger { border-color:#f1b0b7; background:#fff0f2; }
    .row { display:flex; gap:10px; flex-wrap:wrap; align-items:center; }
  </style>
</head>
<body>
  <div class="wrap">
    <h2>Briar Mailbox</h2>
    <p class="muted">No auto-refresh. Use Refresh while pairing. Use Reset to force re-pairing.</p>

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
    </div>

    <script>
      async function loadText(path) {
        const r = await fetch(path, { cache: 'no-store' });
        if (!r.ok) throw new Error(path + " " + r.status);
        return (await r.text()).trim();
      }

      async function refreshUI() {
        let status = "STARTING";
        try { status = await loadText("status.txt"); } catch {}

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
          return;
        }

        stateTag.className = "warn";
        stateTag.textContent = isResetting ? "RESETTING" : (isPairing ? "PAIRING" : (status || "STARTING"));
        connectedBlock.style.display = "none";
        pairBlock.style.display = isPairing ? "block" : "none";

        if (isPairing) {
          try { document.getElementById("link").textContent = await loadText("mailbox.txt") || "(waiting...)"; }
          catch { document.getElementById("link").textContent = "(error loading mailbox.txt)"; }

          try { document.getElementById("ascii").textContent = await loadText("qr_ascii.txt") || "(waiting...)"; }
          catch { document.getElementById("ascii").textContent = "(error loading qr_ascii.txt)"; }
        }
      }

      document.getElementById("resetBtn").addEventListener("click", async () => {
        if (!confirm("Reset mailbox now? This will require pairing again.")) return;
        try {
          const r = await fetch("reset", { method: "POST", cache: "no-store" });
          if (!r.ok) throw new Error("HTTP " + r.status);
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

# Serve /data on 8080 + reset endpoint (touch /data/reset)
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
                self.end_headers()
                self.wfile.write(b"OK\n")
            except Exception as e:
                self.send_response(500)
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

start_briar() {
  : > "$LOG"
  log "Starting Briar mailbox..."
  java -jar /app/briar-mailbox.jar 2>&1 | tee -a "$LOG" &
  echo $!
}

# Supervisor loop: keep Briar running; allow resets at any time.
while true; do
  # If we previously marked CONNECTED, show it immediately (but still watch logs)
  if [[ -f "$CONNECTED_FLAG" ]]; then
    echo "CONNECTED (flag)" > "$STATUS_TXT"
  else
    echo "STARTING" > "$STATUS_TXT"
  fi

  BriarPID="$(start_briar)"

  # Early-state detection window (up to 60s)
  for _ in $(seq 1 60); do
    if [[ -f "$RESET_FLAG" ]]; then
      log "Reset flag detected during startup window."
      kill "$BriarPID" 2>/dev/null || true
      wait "$BriarPID" 2>/dev/null || true
      do_reset_now
      # restart outer loop
      continue 2
    fi

    if ! kill -0 "$BriarPID" 2>/dev/null; then
      echo "ERROR: Briar exited" > "$STATUS_TXT"
      break
    fi

    if saw_pairing_prompt; then
      mark_pairing
      update_pairing_url
      extract_ascii_qr
      break
    fi

    if tor_bootstrapped; then
      mark_connected
      break
    fi

    sleep 1
  done

  # Pairing mode loop: keep updating artifacts until we flip to CONNECTED or reset
  if grep -q "^PAIRING" "$STATUS_TXT" 2>/dev/null; then
    stable_connected=0
    while kill -0 "$BriarPID" 2>/dev/null; do
      if [[ -f "$RESET_FLAG" ]]; then
        log "Reset flag detected during pairing."
        kill "$BriarPID" 2>/dev/null || true
        wait "$BriarPID" 2>/dev/null || true
        do_reset_now
        continue 2
      fi

      update_pairing_url
      extract_ascii_qr

      # Flip to CONNECTED when pairing prompt disappears and Tor is up for ~10s
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

      sleep 1
    done
  fi

  # Connected/steady-state: just keep Briar alive, allow reset
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
      break
    fi

    sleep 1
  done

  sleep 2
done
