#!/usr/bin/with-contenv bash
set -euo pipefail

DATA_DIR="/data"
LOG="/tmp/briar.log"
INDEX="${DATA_DIR}/index.html"
QR_TXT="${DATA_DIR}/mailbox.txt"
QR_PNG="${DATA_DIR}/qr.png"
HTTP_LOG="/tmp/http.log"

mkdir -p "$DATA_DIR"
: > "$LOG"

# Force Briar to use /data (not /root)
export HOME=/data
export XDG_DATA_HOME=/data/.local/share
export XDG_CONFIG_HOME=/data/.config
export XDG_CACHE_HOME=/data/.cache
mkdir -p /data/.local/share /data/.config /data/.cache

# Write placeholder files so UI works immediately
echo "" > "$QR_TXT"
rm -f "$QR_PNG" || true

# Create HTML page (IMPORTANT: RELATIVE paths for HA ingress)
cat > "$INDEX" <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>Briar Mailbox QR</title>
  <style>
    body { font-family: sans-serif; padding: 16px; }
    .wrap { max-width: 640px; margin: 0 auto; }
    img { width: 100%; height: auto; background: #fff; padding: 12px; border-radius: 12px; border: 1px solid #ddd; }
    code { word-break: break-all; display:block; padding: 12px; border: 1px solid #ccc; border-radius: 8px; background: #f7f7f7; }
    .muted { color: #666; }
  </style>
</head>
<body>
  <div class="wrap">
    <h2>Briar Mailbox</h2>
    <p class="muted">If the QR is blank, wait a bit or refresh. This page updates automatically every 2 seconds.</p>

    <h3>QR (will appear when ready)</h3>
    <!-- RELATIVE path: ingress-safe -->
    <p><img id="qr" src="qr.png?ts=0" alt="QR"/></p>

    <h3>Copy/paste link</h3>
    <code id="link">(waiting for mailbox link...)</code>

    <script>
      async function refresh() {
        try {
          // RELATIVE path: ingress-safe
          const resp = await fetch('mailbox.txt', { cache: 'no-store' });
          if (!resp.ok) throw new Error(String(resp.status));
          const t = (await resp.text()).trim();

          document.getElementById('link').textContent =
            t || '(waiting for mailbox link...)';

          // Cache-bust the QR so it appears as soon as generated
          if (t) {
            document.getElementById('qr').src = 'qr.png?ts=' + Date.now();
          }
        } catch (e) {
          document.getElementById('link').textContent =
            '(could not load mailbox.txt: ' + (e && e.message ? e.message : e) + ')';
        }
      }

      refresh();
      setInterval(refresh, 2000);
    </script>
  </div>
</body>
</html>
HTML

# Start web server FIRST so HA ingress can connect immediately
cat > /tmp/server.py <<'PY'
from http.server import SimpleHTTPRequestHandler, HTTPServer
import os

class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        # Serve index.html at "/"
        if self.path == "/":
            self.path = "/index.html"
        return super().do_GET()

os.chdir("/data")
HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY

/opt/venv/bin/python /tmp/server.py >"$HTTP_LOG" 2>&1 &
WebPID=$!
echo "Ingress web server started (pid=$WebPID). Logs: $HTTP_LOG"

# Start Briar mailbox and tee output to a log
echo "Starting Briar mailbox..."
java -jar /app/briar-mailbox.jar > >(tee -a "$LOG") 2>&1 &
BriarPID=$!

echo "Waiting for briar-mailbox URL..."
MAILBOX_URL=""

for i in $(seq 1 180); do
  # If Briar died, stop waiting
  if ! kill -0 "$BriarPID" 2>/dev/null; then
    echo "Briar exited before URL was found."
    break
  fi

  # Match URL even if indented/spaced
  MAILBOX_URL="$(grep -Eo 'briar-mailbox://[^[:space:]]+' "$LOG" | tail -n 1 || true)"
  if [[ -n "$MAILBOX_URL" ]]; then
    break
  fi

  sleep 1
done

if [[ -z "$MAILBOX_URL" ]]; then
  echo "Could not find briar-mailbox URL in logs."
  echo "Last 200 lines:"
  tail -n 200 "$LOG" || true
else
  echo "$MAILBOX_URL" > "$QR_TXT"
  echo "Mailbox URL captured: $MAILBOX_URL"

  # Generate QR PNG (white background works in dark mode)
  /opt/venv/bin/python - <<'PY'
import pathlib
import qrcode
from PIL import Image

txt = pathlib.Path("/data/mailbox.txt").read_text().strip()
if txt:
    qr = qrcode.QRCode(border=2, box_size=10)
    qr.add_data(txt)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white").convert("RGB")
    img.save("/data/qr.png")
else:
    Image.new("RGB", (600, 600), "white").save("/data/qr.png")
PY

  # Helpful debug (shows files exist)
  ls -la /data || true
  ls -la /data/mailbox.txt /data/qr.png || true
fi

# Keep container alive as long as Briar is alive
wait "$BriarPID"
