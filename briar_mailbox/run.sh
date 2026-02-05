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
  : > "$QR_TXT"
  : > "$QR_ASCII"
  update_briar_tail
}

mark_pairing() {
  rm -f "$CONNECTED_FLAG" 2>/dev/null || true
  echo "PAIRING" > "$STATUS_TXT"
  update_briar_tail
}

mark_unknown() {
  echo "RUNNING" > "$STATUS_TXT"
  update_briar_tail
}

consume_reset_request() {
  [[ -f "$RESET_FLAG" ]] || return 1
  # delete immediately (one-shot)
  rm -f "$RESET_FLAG" 2>/dev/null || true
  return 0
}

# Reset must wipe EVERYTHING in /data except a few UI files.
reset_wipe_data_dir() {
  log "RESET: wiping /data state (preserving UI files)..."

  # Stop showing stale stuff
  rm -f "$CONNECTED_FLAG" 2>/dev/null || true
  echo "RESETTING" > "$STATUS_TXT"
  : > "$QR_TXT"
  : > "$QR_ASCII"
  : > "$LOG"
  update_briar_tail

  # Preserve allowlist by moving to temp
  tmp="/tmp/preserve.$$"
  mkdir -p "$tmp"

  for f in "index.html" "status.txt" "briar_tail.txt"; do
    if [[ -f "${DATA_DIR}/${f}" ]]; then
      mv "${DATA_DIR}/${f}" "${tmp}/${f}" 2>/dev/null || true
    fi
  done

  # Nuke everything else in /data (including hidden dirs)
  # shellcheck disable=SC2115
  rm -rf "${DATA_DIR:?}/"* "${DATA_DIR}"/.[!.]* "${DATA_DIR}"/..?* 2>/dev/null || true

  # Restore allowlist
  mkdir -p "$DATA_DIR"
  for f in "index.html" "status.txt" "briar_tail.txt"; do
    if [[ -f "${tmp}/${f}" ]]; then
      mv "${tmp}/${f}" "${DATA_DIR}/${f}" 2>/dev/null || true
    fi
  done
  rm -rf "$tmp" 2>/dev/null || true

  # Recreate dirs Briar expects
  mkdir -p /data/.local/share /data/.config /data/.cache

  : > "$QR_TXT"
  : > "$QR_ASCII"
  : > "$LOG"
  : > "$BRIAR_TAIL"
  echo "STARTING" > "$STATUS_TXT"
  log "RESET: wipe complete."
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
        } else if (isPairing) {
          stateTag.className = "warn";
          stateTag.textContent = "PAIRING";
          connectedBlock.style.display = "none";
          pairBlock.style.display = "block";

          try { document.getElementById("link").textContent = (await loadText("mailbox.txt")).trim() || "(waiting...)"; }
          catch { document.getElementById("link").textContent = "(error loading mailbox.txt)"; }

          try { document.getElementById("ascii").textContent = (await loadText("qr_ascii.txt")).trim() || "(waiting...)"; }
          catch { document.getElementById("ascii").textContent = "(error loading qr_ascii.txt)"; }
        } else {
          stateTag.className = "warn";
          stateTag.textContent = isResetting ? "RESETTING" : (status || "RUNNING");
          connectedBlock.style.display = "none";
          pairBlock.style.display = "none";
        }

        try { document.getElementById("logtail").textContent = (await loadText("briar_tail.txt")).trim() || "(empty)"; }
        catch { document.getElementById("logtail").textContent = "(error loading briar_tail.txt)"; }
      })();
    </script>
  </div>
</body>
</html>
HTML

# --- web server: GET /reset drops a marker then redirects back ---
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

# consume any leftover reset marker from previous run
consume_reset_request >/dev/null 2>&1 || true

while true; do
  # Show persisted connected state if you previously marked it
  if [[ -f "$CONNECTED_FLAG" ]]; then
    echo "CONNECTED (flag)" > "$STATUS_TXT"
  else
    echo "RUNNING" > "$STATUS_TXT"
  fi

  start_briar

  # If we *ever* see pairing prompts, we go PAIRING and keep updating artifacts.
  # If we do NOT see pairing prompts, we do NOT auto-assume connected (Tor alone is meaningless).
  # Connected is only asserted if:
  #   - connected flag already exists, OR
  #   - we saw pairing prompts earlier in this run and they have been absent stably while Tor is up.
  saw_pair_ever="no"
  stable_no_pair=0

  while kill -0 "$BriarPID" 2>/dev/null; do
    if consume_reset_request; then
      log "RESET: request consumed; restarting Briar with wiped /data."
      kill "$BriarPID" 2>/dev/null || true
      wait "$BriarPID" 2>/dev/null || true
      reset_wipe_data_dir
      break
    fi

    if saw_pairing_prompt; then
      saw_pair_ever="yes"
      mark_pairing
      update_pairing_url
      extract_ascii_qr
      stable_no_pair=0
    else
      stable_no_pair=$((stable_no_pair + 1))
    fi

    # Only transition to CONNECTED if we *previously* saw pairing prompts in this run,
    # and now they're gone for ~15s while Tor is up (post-pair stabilization).
    if [[ "$saw_pair_ever" == "yes" ]] && tor_bootstrapped && [[ "$stable_no_pair" -ge 15 ]]; then
      mark_connected
    fi

    # If we are in PAIRING, keep artifacts updated. If not pairing and not connected,
    # just keep status as RUNNING/CONNECTED(flag).
    if grep -q "^PAIRING" "$STATUS_TXT" 2>/dev/null; then
      update_pairing_url
      extract_ascii_qr
    elif [[ -f "$CONNECTED_FLAG" ]]; then
      echo "CONNECTED (flag)" > "$STATUS_TXT"
    else
      mark_unknown
    fi

    update_briar_tail
    sleep 2
  done

  log "Briar exited; restarting in 2s..."
  echo "ERROR: Briar exited" > "$STATUS_TXT"
  update_briar_tail
  sleep 2
done
