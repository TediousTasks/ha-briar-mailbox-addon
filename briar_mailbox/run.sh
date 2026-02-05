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

# Create placeholder files so Ingress never 404s
: > "$QR_TXT"
python - <<'PY'
from PIL import Image
Image.new("RGB", (600, 600), "white").save("/data/qr.png")
PY

# HTML (RELATIVE PATHS ONLY — critical for HA ingress)
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
    .muted { color: #666; }
    .qrframe { background:#fff; padding:16px; border:1px solid #ddd; border-radius:12px; display:inline-block; }
    #qrimg { display:block; width:420px; max-width:100%; height:auto; image-rendering: pixelated; image-rendering: crisp-edges; }
    code { word-break: break-all; display:block; padding:12px; border:1px solid #ccc; border-radius:8px; background:#f7f7f7; }
  </style>
</head>
<body>
  <div class="wrap">
    <h2>Briar Mailbox</h2>
    <p class="muted">This page refreshes every 2 seconds.</p>

    <h3>QR (from Briar output)</h3>
    <div class="qrframe">
      <img id="qrimg" src="qr.png" alt="QR">
    </div>

    <h3>Copy/paste link</h3>
    <code id="link">(waiting...)</code>

    <script>
      async function refresh() {
        try {
          const t = (await (await fetch('mailbox.txt', { cache: 'no-store' })).text()).trim();
          document.getElementById('link').textContent = t || '(waiting...)';
          document.getElementById('qrimg').src = 'qr.png?t=' + Date.now();
        } catch (e) {
          document.getElementById('link').textContent = '(error loading mailbox.txt)';
        }
      }
      refresh();
      setInterval(refresh, 2000);
    </script>
  </div>
</body>
</html>
HTML

# Start web server (Ingress)
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

# Start Briar mailbox
echo "Starting Briar mailbox..."
java -jar /app/briar-mailbox.jar 2>&1 | tee -a "$LOG" &
BriarPID=$!

echo "Waiting for briar-mailbox URL..."
MAILBOX_URL=""

for i in $(seq 1 180); do
  if ! kill -0 "$BriarPID" 2>/dev/null; then
    echo "Briar exited before URL was found."
    break
  fi

  # Grab the FULL url wherever it appears
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

  # Generate QR from the SAME captured URL
  python - <<'PY'
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
fi

wait "$BriarPID"
