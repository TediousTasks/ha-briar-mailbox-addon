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

# Force Briar to use /data
export HOME=/data
export XDG_DATA_HOME=/data/.local/share
export XDG_CONFIG_HOME=/data/.config
export XDG_CACHE_HOME=/data/.cache
mkdir -p /data/.local/share /data/.config /data/.cache

# Ensure files exist so UI doesn't 404
: > "$QR_TXT"
# Create a placeholder QR image so the <img> doesn't 404
/opt/venv/bin/python - <<'PY'
from PIL import Image
Image.new("RGB", (600,600), "white").save("/data/qr.png")
PY

# HTML UI (styling on wrapper, NOT on img)
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

    <h3>QR (from Briar log)</h3>
    <div class="qrframe">
      <img id="qrimg" src="/qr.png" alt="QR">
    </div>

    <h3>Copy/paste link</h3>
    <code id="link">(waiting...)</code>

    <script>
      async function refresh() {
        try {
          const t = (await (await fetch('/mailbox.txt', {cache:'no-store'})).text()).trim();
          document.getElementById('link').textContent = t || '(waiting...)';
          // Bust cache so you see the updated QR when it appears
          document.getElementById('qrimg').src = '/qr.png?t=' + Date.now();
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

# Serve /data on :8080
cat > /tmp/server.py <<'PY'
from http.server import SimpleHTTPRequestHandler, HTTPServer
import os
class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            self.path = "/index.html"
        return super().do_GET()
os.chdir("/data")
HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY

/opt/venv/bin/python /tmp/server.py >"$HTTP_LOG" 2>&1 &
WebPID=$!
echo "Ingress web server started on :8080 (pid=$WebPID)."

echo "Starting Briar mailbox..."
java -jar /app/briar-mailbox.jar > >(tee -a "$LOG") 2>&1 &
BriarPID=$!

echo "Waiting for Briar to print QR + URL..."

# Wait until we see the "Please scan..." block and the briar-mailbox URL
for i in $(seq 1 300); do
  if ! kill -0 "$BriarPID" 2>/dev/null; then
    echo "Briar exited unexpectedly."
    tail -n 200 "$LOG" || true
    exit 1
  fi

  if grep -q "Please scan this with the Briar Android app" "$LOG" && grep -q "Or copy and paste this into Briar Desktop" "$LOG"; then
    break
  fi
  sleep 1
done

# Extract the URL (used for display/copy)
MAILBOX_URL="$(grep -Eo 'briar-mailbox://[^[:space:]]+' "$LOG" | tail -n 1 || true)"
if [[ -n "$MAILBOX_URL" ]]; then
  echo "$MAILBOX_URL" > "$QR_TXT"
  echo "Mailbox URL captured: $MAILBOX_URL"
else
  echo "Could not find briar-mailbox:// URL."
fi

# Extract the ASCII QR block EXACTLY from the log and render it
# This takes everything between the scan line and the "Or copy..." line, excluding both.
awk '
  /Please scan this with the Briar Android app/ {inblock=1; next}
  /Or copy and paste this into Briar Desktop/ {inblock=0}
  inblock {print}
' "$LOG" > /tmp/qr_ascii.txt

# Render ASCII QR -> PNG
/opt/venv/bin/python - <<'PY'
from PIL import Image
import pathlib

lines = pathlib.Path("/tmp/qr_ascii.txt").read_text().splitlines()

# Drop empty lines at start/end
while lines and not lines[0].strip():
    lines.pop(0)
while lines and not lines[-1].strip():
    lines.pop()

if not lines:
    raise SystemExit("No ASCII QR block found to render")

# Treat any non-space as black
h = len(lines)
w = max(len(l) for l in lines)

# Normalize line lengths
norm = [l.ljust(w) for l in lines]

scale = 6  # pixels per character cell (bigger = easier scan)
img = Image.new("RGB", (w * scale, h * scale), "white")
px = img.load()

for y, row in enumerate(norm):
    for x, ch in enumerate(row):
        black = (ch != ' ')
        if black:
            for dy in range(scale):
                for dx in range(scale):
                    px[x*scale+dx, y*scale+dy] = (0,0,0)

# Add a quiet border around the whole thing (extra white margin)
border = 24
out = Image.new("RGB", (img.width + 2*border, img.height + 2*border), "white")
out.paste(img, (border, border))
out.save("/data/qr.png", "PNG", optimize=False)
PY

echo "Rendered log QR to /data/qr.png"

wait "$BriarPID"
