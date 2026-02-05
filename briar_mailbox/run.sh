#!/usr/bin/with-contenv bash
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

# Force Briar to use /data (not /root)
export HOME=/data
export XDG_DATA_HOME=/data/.local/share
export XDG_CONFIG_HOME=/data/.config
export XDG_CACHE_HOME=/data/.cache

mkdir -p /data/.local/share /data/.config /data/.cache

: > "$LOG"
: > "$QR_TXT"
: > "$QR_ASCII"
: > "$BRIAR_TAIL"
echo "STARTING" > "$STATUS_TXT"

log() { echo "[$(date -Is)] $*" >&2; }

update_briar_tail() {
  tail -n 200 "$LOG" > "$BRIAR_TAIL" 2>/dev/null || true
}

mark_connected() {
  date -Is > "$CONNECTED_FLAG"
  echo "CONNECTED" > "$STATUS_TXT"
  # Hide pairing artifacts
  : > "$QR_TXT"
  : > "$QR_ASCII"
  update_briar_tail
}

mark_pairing() {
  rm -f "$CONNECTED_FLAG" 2>/dev/null || true
  echo "PAIRING" > "$STATUS_TXT"
  update_briar_tail
}

# Consume reset request immediately so it can't loop on restart
consume_reset_request() {
  [[ -f "$RESET_FLAG" ]] || return 1

  local ts now age
  ts="$(head -n 1 "$RESET_FLAG" 2>/dev/null || true)"
  now="$(date +%s)"

  # delete immediately (one-shot)
  rm -f "$RESET_FLAG" 2>/dev/null || true

  # ignore stale reset requests (> 10 minutes)
  if [[ "$ts" =~ ^[0-9]+$ ]]; then
    age=$((now - ts))
    if (( age > 600 )); then
      log "Ignoring stale reset request (age ${age}s)."
      return 1
    fi
  fi

  return 0
}

do_reset_now() {
  log "RESET: wiping Briar state under /data to force re-pairing..."
  echo "RESETTING" > "$STATUS_TXT"

  rm -f "$CONNECTED_FLAG" 2>/dev/null || true
  : > "$QR_TXT"
  : > "$QR_ASCII"

  # HARD WIPE: Briar should only be using these because we force HOME/XDG_*
  rm -rf /data/.local 2>/dev/null || true
  rm -rf /data/.config 2>/dev/null || true
  rm -rf /data/.cache 2>/dev/null || true

  # Recreate required dirs
  mkdir -p /data/.local/share /data/.config /data/.cache

  # Clear runtime log so next start shows fresh behavior
  : > "$LOG"
  update_briar_tail
  log "RESET: complete."
}

# --- UI (relative paths only for ingress) ---
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
        <a class="btn btn-danger" href="reset" id="resetLink">Reset mailbox (force re-pair)</a>
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
      // confirm reset
      document.getElementById("resetLink").addEventListener("click", (e) => {
        if (!confirm("Reset mailbox now? This will require pairing again.")) {
          e.preventDefault();
        }
      });

      async function loadText(path) {
        const r = await fetch(path, { cache: 'no-store' });
        if (!r.ok) throw new Error(path + " " + r.status);
        return (await r.text());
      }

      (async () => {
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

          if (isPairing) {
            try { document.getElementById("link").textContent = (await loadText("mailbox.txt")).trim() || "(waiting...)"; }
            catch { document.getElementById("link").textContent = "(error loading mailbox.txt)"; }

            try { document.getElementById("ascii").textContent = (await loadText("qr_ascii.txt")).trim() || "(waiting...)"; }
            catch { document.getElementById("ascii").textContent = "(error loading qr_ascii.txt)"; }
          }
        }

        try { document.getElementById("logtail").textContent = (await loadText("briar_tail.txt")).trim() || "(empty)"; }
        catch { document.getElementById("logtail").textContent = "(error loading briar_tail.txt)"; }
      })();
    </script>
  </div>
</body>
</html>
HTML

# --- web server: GET /reset writes a timestamp to /data/reset then redirects back ---
cat > /tmp/server.py <<'PY'
from http.server import SimpleHTTPRequestHandler, HTTPServer
import os, time

DATA_DIR = "/data"
RESET_FLAG = os.path.join(DATA_DIR, "reset")

class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        # redirect root to UI
        if self.path == "/" or self.path.startswith("/?"):
            self.path = "/index.html"
            return super().do_GET()

        # reset endpoint: create /data/reset and redirect to /
        if self.path.rstrip("/") == "/reset":
            try:
                with open(RESET_FLAG, "w", encoding="utf-8") as f:
                    f.write(str(int(time.time())) + "\n")
            except Exception:
                pass
            self.send_response(302)
            self.send_header("Location", "./")
            self.end_headers()
            return

        return super().do_GET()

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

BriarPID=""

start_briar() {
  : > "$LOG"
  update_briar_tail
  log "Starting Briar mailbox..."
  echo "STARTING (launching Briar)" > "$STATUS_TXT"

  set +e
  java -jar /app/briar-mailbox.jar 2>&1 | tee -a "$LOG" &
  BriarPID="$!"
  set -e

  log "Briar PID: $BriarPID"
  update_briar_tail
}

# consume any stale reset on startup
consume_reset_request >/dev/null 2>&1 || true

while true; do
  # show persisted state quickly
  if [[ -f "$CONNECTED_FLAG" ]]; then
    echo "CONNECTED (flag)" > "$STATUS_TXT"
  else
    echo "STARTING" > "$STATUS_TXT"
  fi

  start_briar

  # Decision window: up to 45s
  # - If we see pairing prompts -> PAIRING
  # - If we never see pairing prompts for long enough and Tor bootstraps -> CONNECTED
  saw_pair="no"
  stable_no_pair=0

  for _ in $(seq 1 45); do
    if consume_reset_request; then
      log "Reset request consumed during startup."
      kill "$BriarPID" 2>/dev/null || true
      wait "$BriarPID" 2>/dev/null || true
      do_reset_now
      break
    fi

    if ! kill -0 "$BriarPID" 2>/dev/null; then
      echo "ERROR: Briar exited" > "$STATUS_TXT"
      update_briar_tail
      break
    fi

    if saw_pairing_prompt; then
      saw_pair="yes"
      mark_pairing
      update_pairing_url
      extract_ascii_qr
      update_briar_tail
      break
    else
      stable_no_pair=$((stable_no_pair + 1))
    fi

    # Only declare connected if:
    # - tor is fully bootstrapped
    # - and we have had ~15s with no pairing prompt
    if tor_bootstrapped && [[ "$stable_no_pair" -ge 15 ]]; then
      mark_connected
      break
    fi

    update_briar_tail
    sleep 1
  done

  # If PAIRING, keep updating until reset or process dies.
  if grep -q "^PAIRING" "$STATUS_TXT" 2>/dev/null; then
    while kill -0 "$BriarPID" 2>/dev/null; do
      if consume_reset_request; then
        log "Reset request consumed during pairing."
        kill "$BriarPID" 2>/dev/null || true
        wait "$BriarPID" 2>/dev/null || true
        do_reset_now
        break
      fi

      update_pairing_url
      extract_ascii_qr
      update_briar_tail
      sleep 2
    done
    sleep 2
    continue
  fi

  # Steady-state: keep running; allow reset
  while true; do
    if consume_reset_request; then
      log "Reset request consumed during steady-state."
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
