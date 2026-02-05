#!/usr/bin/with-contenv bash
set -euo pipefail

DATA_DIR="/data"
LOG="/tmp/briar.log"
INDEX="${DATA_DIR}/index.html"
ASCII_TXT="${DATA_DIR}/ascii.txt"
URL_TXT="${DATA_DIR}/mailbox.txt"
HTTP_LOG="/tmp/http.log"

mkdir -p "$DATA_DIR"
: > "$LOG"

# Force Briar to use /data (not /root)
export HOME=/data
export XDG_DATA_HOME=/data/.local/share
export XDG_CONFIG_HOME=/data/.config
export XDG_CACHE_HOME=/data/.cache
mkdir -p /data/.local/share /data/.config /data/.cache

# Create placeholder files FIRST so UI never 404s
: > "$ASCII_TXT"
: > "$URL_TXT"

# ---- Web UI (served from /data) ----
cat > "$INDEX" <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>Briar Mailbox</title>
  <style>
    :root { --bg:#fff; --fg:#111; --muted:#666; --card:#f7f7f7; --border:#ddd; --codebg:#f3f3f3; }
    @media (prefers-color-scheme: dark) {
      :root { --bg:#0f1115; --fg:#e7e7e7; --muted:#a7a7a7; --card:#171a21; --border:#2a2f3a; --codebg:#141821; }
    }
    body{font-family:system-ui,sans-serif;margin:0;background:var(--bg);color:var(--fg);}
    .wrap{max-width:840px;margin:0 auto;padding:16px;}
    .muted{color:var(--muted);}
    .card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:12px;}
    pre{margin:0;padding:12px;background:var(--codebg);border:1px solid var(--border);border-radius:12px;overflow-x:auto;
        font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,"Liberation Mono",monospace;
        line-height:1.05;font-size:12px;white-space:pre;}
    code{display:block;padding:12px;background:var(--codebg);border:1px solid var(--border);border-radius:12px;word-break:break-all;
         font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,"Liberation Mono",monospace;}
    .row{display:grid;gap:12px;}
    button{border:1px solid var(--border);background:transparent;color:var(--fg);padding:8px 10px;border-radius:10px;cursor:pointer;}
  </style>
</head>
<body>
  <div class="wrap">
    <h2>Briar Mailbox</h2>
    <p class="muted">This page refreshes every 2 seconds.</p>

    <div class="row">
      <div class="card">
        <h3 style="margin:0 0 8px 0;">ASCII QR (from Briar log)</h3>
        <pre id="ascii">(waiting for ASCII QR...)</pre>
      </div>

      <div class="card">
        <h3 style="margin:0 0 8px 0;">Desktop link</h3>
        <code id="link">(waiting for briar-mailbox:// link...)</code>
        <div style="display:flex; gap:8px; margin-top:10px;">
          <button id="copy" type="button">Copy link</button>
          <span class="muted" id="copystatus"></span>
        </div>
      </div>
    </div>
  </div>

  <script>
    async function refresh() {
      try {
        const ascii = await (await fetch('/ascii.txt', { cache: 'no-store' })).text();
        document.getElementById('ascii').textContent =
          ascii.trim() ? ascii.replace(/\r/g,'') : '(waiting for ASCII QR...)';
      } catch {
        document.getElementById('ascii').textContent = '(could not load ascii.txt)';
      }

      try {
        const link = (await (await fetch('/mailbox.txt', { cache: 'no-store' })).text()).trim();
        document.getElementById('link').textContent = link || '(waiting for briar-mailbox:// link...)';
      } catch {
        document.getElementById('link').textContent = '(could not load mailbox.txt)';
      }
    }

    document.getElementById('copy').addEventListener('click', async () => {
      const link = document.getElementById('link').textContent.trim();
      const status = document.getElementById('copystatus');
      if (!link || link.startsWith('(waiting') || link.startsWith('(could not')) {
        status.textContent = 'No link yet';
        return;
      }
      try {
        await navigator.clipboard.writeText(link);
        status.textContent = 'Copied';
        setTimeout(() => status.textContent = '', 1200);
      } catch {
        status.textContent = 'Copy failed';
      }
    });

    refresh();
    setInterval(refresh, 2000);
  </script>
</body>
</html>
HTML

# ---- HTTP server that NEVER 404s for ascii.txt/mailbox.txt ----
cat > /tmp/server.py <<'PY'
from http.server import SimpleHTTPRequestHandler, HTTPServer
import os

DATA_DIR = "/data"

class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        # Map root to index.html
        if self.path == "/":
            self.path = "/index.html"

        # For these, always return 200 even if file missing
        if self.path in ("/ascii.txt", "/mailbox.txt"):
            path = os.path.join(DATA_DIR, self.path.lstrip("/"))
            try:
                with open(path, "rb") as f:
                    data = f.read()
            except FileNotFoundError:
                data = b""
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        return super().do_GET()

os.chdir(DATA_DIR)
HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY

python3 /tmp/server.py >"$HTTP_LOG" 2>&1 &
WebPID=$!
echo "Ingress web server started (pid=$WebPID). Logs: $HTTP_LOG"

# ---- Start Briar and capture output ----
echo "Starting Briar mailbox..."
java -jar /app/briar-mailbox.jar > >(tee -a "$LOG") 2>&1 &
BriarPID=$!

echo "Waiting for Briar ASCII QR + mailbox URL..."

for i in $(seq 1 240); do
  if ! kill -0 "$BriarPID" 2>/dev/null; then
    echo "Briar exited before capture completed."
    break
  fi

  # Extract ASCII block (between the two known log lines)
  awk '
    BEGIN {inside=0}
    /Please scan this with the Briar Android app:/ {inside=1; next}
    /Or copy and paste this into Briar Desktop:/ {inside=0}
    inside==1 {print}
  ' "$LOG" > "$ASCII_TXT" || true

  # Extract URL anywhere in the log line
  URL="$(grep -Eo 'briar-mailbox://[^[:space:]]+' "$LOG" | tail -n 1 || true)"
  if [[ -n "${URL:-}" ]]; then
    printf '%s\n' "$URL" > "$URL_TXT"
  fi

  if [[ -s "$ASCII_TXT" && -s "$URL_TXT" ]]; then
    echo "Captured ASCII QR and mailbox URL."
    break
  fi

  sleep 1
done

# Keep container alive as long as Briar is alive
wait "$BriarPID"
