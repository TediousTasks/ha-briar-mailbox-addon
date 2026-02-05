#!/usr/bin/with-contenv bash
set -euo pipefail

DATA_DIR="/data"
LOG="/tmp/briar.log"
HTTP_LOG="/tmp/http.log"

INDEX="${DATA_DIR}/index.html"
STATUS_TXT="${DATA_DIR}/status.txt"
BRIAR_TAIL="${DATA_DIR}/briar_tail.txt"
CONTROL_LOG="${DATA_DIR}/control.log"

CONNECTED_FLAG="${DATA_DIR}/connected"
RESET_FLAG="${DATA_DIR}/reset"

mkdir -p "$DATA_DIR"
touch "$CONTROL_LOG"

# Force Briar to use /data (not /root)
export HOME=/data
export XDG_DATA_HOME=/data/.local/share
export XDG_CONFIG_HOME=/data/.config
export XDG_CACHE_HOME=/data/.cache

mkdir -p /data/.local/share /data/.config /data/.cache

: > "$LOG"
: > "$BRIAR_TAIL"
echo "STARTING" > "$STATUS_TXT"

log() {
  local msg="[$(date -Is)] $*"
  echo "$msg" >&2
  echo "$msg" >> "$CONTROL_LOG"
}

update_briar_tail() {
  tail -n 250 "$LOG" > "$BRIAR_TAIL" 2>/dev/null || true
}

consume_reset_request() {
  [[ -f "$RESET_FLAG" ]] || return 1
  rm -f "$RESET_FLAG" 2>/dev/null || true
  return 0
}

dump_data_tree_to_control() {
  {
    echo "----- /data tree @ $(date -Is) -----"
    echo "whoami=$(whoami 2>/dev/null || true) uid=$(id -u) gid=$(id -g)"
    ls -la /data || true
    echo
    find /data -maxdepth 3 -print 2>/dev/null || true
    echo "-----------------------------------"
  } >> "$CONTROL_LOG"
}

stop_briar_hard() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0

  if ! kill -0 "$pid" 2>/dev/null; then
    log "Stop: Briar PID $pid not running."
    return 0
  fi

  log "Stop: sending SIGTERM to $pid..."
  kill "$pid" 2>/dev/null || true

  for _ in $(seq 1 10); do
    if ! kill -0 "$pid" 2>/dev/null; then
      log "Stop: PID $pid exited after SIGTERM."
      return 0
    fi
    sleep 0.5
  done

  log "Stop: still running; sending SIGKILL to $pid..."
  kill -9 "$pid" 2>/dev/null || true

  for _ in $(seq 1 10); do
    if ! kill -0 "$pid" 2>/dev/null; then
      log "Stop: PID $pid exited after SIGKILL."
      return 0
    fi
    sleep 0.5
  done

  log "Stop: WARNING: PID $pid still appears alive after SIGKILL. Continuing anyway."
}

fix_data_permissions() {
  local uid gid
  uid="$(id -u)"
  gid="$(id -g)"

  # Make sure base dirs exist
  mkdir -p /data/.local/share /data/.config /data/.cache

  # Ensure writable for the running user
  chown -R "${uid}:${gid}" /data 2>/dev/null || true

  chmod 755 /data 2>/dev/null || true
  chmod 700 /data/.config /data/.cache 2>/dev/null || true
  chmod -R u+rwX /data/.local 2>/dev/null || true

  log "Perms: ensured /data owned by ${uid}:${gid} and writable."
}

log_possible_tor_artifacts() {
  # If onionwrapper/tor wrote anything into /data, capture it for debugging
  {
    echo "----- Tor artifacts scan @ $(date -Is) -----"
    find /data -maxdepth 5 -type f \( -iname "*tor*" -o -iname "*onion*" -o -iname "*log*" \) -print 2>/dev/null || true
    echo "-------------------------------------------"
  } >> "$CONTROL_LOG"
}

hard_wipe_data_dir_except_ui() {
  log "RESET: dumping /data BEFORE wipe..."
  dump_data_tree_to_control

  log "RESET: wiping /data (preserve UI files only)..."
  echo "RESETTING" > "$STATUS_TXT"

  rm -f "$CONNECTED_FLAG" 2>/dev/null || true
  : > "$LOG"
  update_briar_tail

  : > /tmp/reset_rm_err.log

  # Preserve allowlist: index.html, status.txt, briar_tail.txt, control.log
  find /data -mindepth 1 \
    \( -path "/data/index.html" -o -path "/data/status.txt" -o -path "/data/briar_tail.txt" -o -path "/data/control.log" \) -prune -o \
    -exec rm -rf {} + 2>>/tmp/reset_rm_err.log || true

  leftover="$(find /data -mindepth 1 \
    \( -path "/data/index.html" -o -path "/data/status.txt" -o -path "/data/briar_tail.txt" -o -path "/data/control.log" \) -prune -o \
    -print | head -n 200 || true)"

  if [[ -n "$leftover" ]]; then
    log "RESET WARNING: leftover items after wipe (first 200):"
    echo "$leftover" >> "$CONTROL_LOG"
    if [[ -s /tmp/reset_rm_err.log ]]; then
      log "RESET rm errors (first 200 lines):"
      sed -n '1,200p' /tmp/reset_rm_err.log >> "$CONTROL_LOG" || true
    fi
  else
    log "RESET: wipe verification PASSED."
  fi

  # Recreate dirs + fix perms (CRITICAL for Tor + onionwrapper)
  mkdir -p /data/.local/share /data/.config /data/.cache
  fix_data_permissions

  : > "$LOG"
  : > "$BRIAR_TAIL"
  update_briar_tail

  log "RESET: dumping /data AFTER wipe..."
  dump_data_tree_to_control

  echo "STARTING" > "$STATUS_TXT"
  log "RESET: wipe complete."
}

# --- UI ---
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
    .ok { display:inline-block; padding:6px 10px; border-radius:999px; background:#e9f7ef; border:1px solid #bfe8cf; }
    .warn { display:inline-block; padding:6px 10px; border-radius:999px; background:#fff6e5; border:1px solid #ffe0a3; }
    .btn { display:inline-block; padding:10px 12px; border:1px solid #ccc; border-radius:10px; background:#f7f7f7; text-decoration:none; color:#000; cursor:pointer; }
    .btn-danger { border-color:#f1b0b7; background:#fff0f2; }
    .row { display:flex; gap:10px; flex-wrap:wrap; align-items:center; }
  </style>
</head>
<body>
  <div class="wrap">
    <h2>Briar Mailbox</h2>
    <p class="muted">Refresh to update. Reset wipes /data state and requires pairing again.</p>

    <div class="card">
      <div class="row">
        <div id="stateTag" class="warn">Loading…</div>
        <a class="btn" href="./">Refresh</a>
        <a class="btn btn-danger" href="reset" id="resetLink">Reset</a>
      </div>

      <h3>Control log</h3>
      <pre id="ctl">(loading...)</pre>

      <h3>Briar log tail</h3>
      <pre id="tail">(loading...)</pre>
    </div>

    <script>
      document.getElementById("resetLink").addEventListener("click", (e) => {
        if (!confirm("Reset now? This wipes /data state and requires pairing again.")) e.preventDefault();
      });

      async function loadText(path) {
        const r = await fetch(path, { cache: 'no-store' });
        if (!r.ok) throw new Error(path + " " + r.status);
        return await r.text();
      }

      (async () => {
        let status = "STARTING";
        try { status = (await loadText("status.txt")).trim(); } catch {}
        const tag = document.getElementById("stateTag");
        const s = (status || "").toUpperCase();
        if (s.startsWith("CONNECTED")) { tag.className="ok"; tag.textContent="CONNECTED"; }
        else if (s.startsWith("RESETTING")) { tag.className="warn"; tag.textContent="RESETTING"; }
        else { tag.className="warn"; tag.textContent = status || "RUNNING"; }

        try { document.getElementById("ctl").textContent = (await loadText("control.log")).trim() || "(empty)"; }
        catch { document.getElementById("ctl").textContent="(error loading control.log)"; }

        try { document.getElementById("tail").textContent = (await loadText("briar_tail.txt")).trim() || "(empty)"; }
        catch { document.getElementById("tail").textContent="(error loading briar_tail.txt)"; }
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

python /tmp/server.py >/tmp/http.log 2>&1 &
log "HTTP server started on :8080. Logs: /tmp/http.log"

BriarPID=""

start_briar() {
  : > "$LOG"
  update_briar_tail
  log "Starting Briar mailbox..."
  echo "RUNNING" > "$STATUS_TXT"

  # Make sure permissions are sane on every start
  fix_data_permissions

  java -jar /app/briar-mailbox.jar 2>&1 | tee -a "$LOG" &
  BriarPID="$!"
  log "Briar PID: $BriarPID"
}

start_briar

while true; do
  if consume_reset_request; then
    log "RESET: request consumed; stopping Briar..."
    stop_briar_hard "$BriarPID"
    hard_wipe_data_dir_except_ui
    log "RESET: restarting Briar..."
    start_briar
  fi

  if ! kill -0 "$BriarPID" 2>/dev/null; then
    log "Briar exited; restarting..."
    log_possible_tor_artifacts
    echo "ERROR: Briar exited" > "$STATUS_TXT"
    sleep 2
    start_briar
  fi

  update_briar_tail
  sleep 2
done
