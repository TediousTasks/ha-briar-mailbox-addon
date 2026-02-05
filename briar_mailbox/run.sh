#!/usr/bin/with-contenv bash
set -euo pipefail

DATA_DIR="/data"
LOG="/tmp/briar.log"
HTTP_LOG="/tmp/http.log"

INDEX="${DATA_DIR}/index.html"
STATUS_TXT="${DATA_DIR}/status.txt"
QR_ASCII="${DATA_DIR}/qr_ascii.txt"
QR_TXT="${DATA_DIR}/mailbox.txt"

RESET_FLAG="${DATA_DIR}/reset"

mkdir -p "$DATA_DIR"

# Force Briar to use /data (not /root)
export HOME=/data
export XDG_DATA_HOME=/data/.local/share
export XDG_CONFIG_HOME=/data/.config
export XDG_CACHE_HOME=/data/.cache
mkdir -p /data/.local/share /data/.config /data/.cache

: > "$LOG"
: > "$QR_ASCII"
: > "$QR_TXT"
echo "STARTING" > "$STATUS_TXT"

log() { echo "[$(date -Is)] $*" >&2; }

consume_reset_request() {
  [[ -f "$RESET_FLAG" ]] || return 1
  rm -f "$RESET_FLAG" 2>/dev/null || true
  return 0
}

fix_data_permissions() {
  local uid gid
  uid="$(id -u)"
  gid="$(id -g)"
  mkdir -p /data/.local/share /data/.config /data/.cache
  chown -R "${uid}:${gid}" /data 2>/dev/null || true
  chmod 755 /data 2>/dev/null || true
  chmod 700 /data/.config /data/.cache 2>/dev/null || true
  chmod -R u+rwX /data/.local 2>/dev/null || true
}

kill_orphan_tor() {
  local patterns=(
    "/data/.*/tor"
    "/data/.*/obfs4proxy"
    "/data/.*/snowflake"
    "obfs4proxy"
    "snowflake"
    " tor "
  )

  local killed="no"
  for pat in "${patterns[@]}"; do
    local pids
    pids="$(pgrep -f "$pat" 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
      killed="yes"
      log "Cleanup: TERM '$pat' pids: $pids"
      kill $pids 2>/dev/null || true
    fi
  done

  sleep 1

  for pat in "${patterns[@]}"; do
    local pids
    pids="$(pgrep -f "$pat" 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
      log "Cleanup: KILL '$pat' pids: $pids"
      kill -9 $pids 2>/dev/null || true
    fi
  done

  [[ "$killed" == "yes" ]] && sleep 1
}

stop_briar_hard() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 0

  if kill -0 "$pid" 2>/dev/null; then
    log "Stop: SIGTERM $pid"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 12); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
      log "Stop: SIGKILL $pid"
      kill -9 "$pid" 2>/dev/null || true
      sleep 0.5
    fi
  fi

  kill_orphan_tor
}

wipe_data_dir_preserve_ui() {
  echo "RESETTING" > "$STATUS_TXT"
  : > "$LOG"
  : > "$QR_ASCII"
  : > "$QR_TXT"

  find /data -mindepth 1 \
    \( -path "/data/index.html" -o -path "/data/status.txt" -o -path "/data/qr_ascii.txt" -o -path "/data/mailbox.txt" \) -prune -o \
    -exec rm -rf {} + || true

  mkdir -p /data/.local/share /data/.config /data/.cache
  fix_data_permissions
  kill_orphan_tor

  echo "STARTING" > "$STATUS_TXT"
}

# --- Log parsing / state ---
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
except Exception:
    lines = []
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
  grep -q "Bootstrapped 100% (done): Done" "$LOG"
}

tor_progress_pct() {
  # returns an integer 0-100, best effort
  local pct=""
  pct="$(grep -Eo 'Bootstrapped [0-9]{1,3}% ' "$LOG" | tail -n 1 | grep -Eo '[0-9]{1,3}' || true)"
  if [[ -z "$pct" ]]; then
    echo 0
  else
    echo "$pct"
  fi
}

# --- Clean UI page ---
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
    code { word-break: break-all; display:block; padding:12px; border:1px solid #ddd; border-radius:8px; background:#f7f7f7; }
    .tag { display:inline-block; padding:6px 10px; border-radius:999px; border:1px solid #ddd; background:#f7f7f7; }
    .tag.ok { background:#e9f7ef; border-color:#bfe8cf; }
    .tag.warn { background:#fff6e5; border-color:#ffe0a3; }
    .row { display:flex; gap:10px; flex-wrap:wrap; align-items:center; margin-top:10px; }
    .btn { display:inline-block; padding:10px 12px; border:1px solid #ccc; border-radius:10px; background:#f7f7f7; text-decoration:none; color:#000; cursor:pointer; }
    .btn-danger { border-color:#f1b0b7; background:#fff0f2; }
  </style>
</head>
<body>
  <div class="wrap">
    <h2>Briar Mailbox</h2>
    <p class="muted">If pairing is shown, click Refresh after a few seconds to update.</p>

    <div class="card">
      <div class="row">
        <div id="stateTag" class="tag warn">Loading…</div>
        <a class="btn" href="./">Refresh</a>
        <a class="btn btn-danger" href="reset" id="resetLink">Reset</a>
      </div>

      <div id="connectedBlock" style="display:none; margin-top:14px;">
        <h3>Connected</h3>
        <p class="muted">This mailbox appears to already be configured and running.</p>
      </div>

      <div id="pairBlock" style="display:none; margin-top:14px;">
        <h3>Pairing</h3>
        <p class="muted">Scan the ASCII QR in the Briar Android app, or copy the desktop link.</p>

        <h4>ASCII QR</h4>
        <pre id="ascii">(waiting...)</pre>

        <h4>Desktop link</h4>
        <code id="link">(waiting...)</code>
      </div>

      <div id="startingBlock" style="display:none; margin-top:14px;">
        <h3>Starting</h3>
        <p class="muted">Briar is starting up. Refresh in a few seconds.</p>
      </div>

      <div id="errorBlock" style="display:none; margin-top:14px;">
        <h3>Error</h3>
        <p class="muted">Briar failed to start. Try Reset.</p>
      </div>
    </div>

    <script>
      document.getElementById("resetLink").addEventListener("click", (e) => {
        if (!confirm("Reset now? This wipes /data and requires pairing again.")) e.preventDefault();
      });

      async function loadText(path) {
        const r = await fetch(path, { cache: 'no-store' });
        if (!r.ok) throw new Error(path + " " + r.status);
        return (await r.text()).trim();
      }

      (async () => {
        let status = "STARTING";
        try { status = await loadText("status.txt"); } catch {}

        const tag = document.getElementById("stateTag");
        const connected = document.getElementById("connectedBlock");
        const pairing = document.getElementById("pairBlock");
        const starting = document.getElementById("startingBlock");
        const error = document.getElementById("errorBlock");

        const s = (status || "").toUpperCase();

        function show(which) {
          connected.style.display = which === "connected" ? "block" : "none";
          pairing.style.display   = which === "pairing"   ? "block" : "none";
          starting.style.display  = which === "starting"  ? "block" : "none";
          error.style.display     = which === "error"     ? "block" : "none";
        }

        if (s.startsWith("CONNECTED")) {
          tag.className = "tag ok";
          tag.textContent = "CONNECTED";
          show("connected");
          return;
        }

        if (s.startsWith("PAIRING")) {
          tag.className = "tag warn";
          tag.textContent = "PAIRING";
          show("pairing");

          try { document.getElementById("ascii").textContent = await loadText("qr_ascii.txt") || "(waiting...)"; }
          catch { document.getElementById("ascii").textContent = "(error loading qr_ascii.txt)"; }

          try { document.getElementById("link").textContent = await loadText("mailbox.txt") || "(waiting...)"; }
          catch { document.getElementById("link").textContent = "(error loading mailbox.txt)"; }

          return;
        }

        if (s.startsWith("ERROR")) {
          tag.className = "tag warn";
          tag.textContent = "ERROR";
          show("error");
          return;
        }

        tag.className = "tag warn";
        tag.textContent = status || "STARTING";
        show("starting");
      })();
    </script>
  </div>
</body>
</html>
HTML

# --- web server: GET /reset drops marker then redirects back ---
cat > /tmp/server.py <<'PY'
from http.server import SimpleHTTPRequestHandler, HTTPServer
import os, time

DATA_DIR = "/data"
RESET_FLAG = os.path.join(DATA_DIR, "reset")

class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/" or self.path.startswith("/?"):
            self.path = "/index.html"
            return super().do_GET()

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

BriarPID=""

start_briar() {
  : > "$LOG"
  : > "$QR_ASCII"
  : > "$QR_TXT"
  echo "STARTING" > "$STATUS_TXT"

  fix_data_permissions
  kill_orphan_tor

  log "Starting Briar mailbox..."
  java -jar /app/briar-mailbox.jar 2>&1 | tee -a "$LOG" &
  BriarPID="$!"
  log "Briar PID: $BriarPID"
}

decide_state_window() {
  # up to ~90 seconds to reach either PAIRING (after tor >=10%) or CONNECTED
  for _ in $(seq 1 90); do
    if ! kill -0 "$BriarPID" 2>/dev/null; then
      echo "ERROR" > "$STATUS_TXT"
      return 0
    fi

    if saw_pairing_prompt; then
      echo "PAIRING" > "$STATUS_TXT"
      update_pairing_url
      extract_ascii_qr
      return 0
    fi

    if tor_bootstrapped; then
      echo "CONNECTED" > "$STATUS_TXT"
      return 0
    fi

    # If Tor is progressing (>=10%), we should present as PAIRING even if prompt hasn't printed yet
    pct="$(tor_progress_pct)"
    if [[ "$pct" -ge 10 ]]; then
      echo "PAIRING" > "$STATUS_TXT"
      update_pairing_url
      extract_ascii_qr
      return 0
    fi

    sleep 1
  done

  echo "STARTING" > "$STATUS_TXT"
}

start_briar
decide_state_window

while true; do
  if consume_reset_request; then
    log "RESET: requested"
    stop_briar_hard "$BriarPID"
    wipe_data_dir_preserve_ui
    start_briar
    decide_state_window
  fi

  if ! kill -0 "$BriarPID" 2>/dev/null; then
    echo "ERROR" > "$STATUS_TXT"
    sleep 2
    start_briar
    decide_state_window
  fi

  # While pairing, keep updating artifacts so Refresh shows current data
  if grep -q "^PAIRING" "$STATUS_TXT"; then
    update_pairing_url
    extract_ascii_qr

    # Flip to CONNECTED after stable 100% + no pairing prompt
    stable=0
    for _ in $(seq 1 10); do
      if ! kill -0 "$BriarPID" 2>/dev/null; then
        stable=0
        break
      fi
      if tor_bootstrapped && ! saw_pairing_prompt; then
        stable=$((stable + 1))
      else
        stable=0
      fi
      sleep 1
    done

    if [[ "$stable" -ge 10 ]]; then
      echo "CONNECTED" > "$STATUS_TXT"
      : > "$QR_ASCII"
      : > "$QR_TXT"
    fi
  fi

  sleep 2
done
