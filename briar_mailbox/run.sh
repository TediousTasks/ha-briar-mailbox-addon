#!/usr/bin/with-contenv bash
set -euo pipefail

DATA_DIR="/data"
LOG="/tmp/briar.log"
INDEX="${DATA_DIR}/index.html"
QR_TXT="${DATA_DIR}/mailbox.txt"
QR_PNG="${DATA_DIR}/qr.png"
QR_ASCII="${DATA_DIR}/qr_ascii.txt"
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
: > "$QR_ASCII"

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
    .wrap { max-width: 760px; margin: 0 auto; }
    .muted { color: #666; }
    .qrframe { background:#fff; padding:16px; border:1px solid #ddd; border-radius:12px; display:inline-block; }
    #qrimg { display:block; width:520px; max-width:100%; height:auto; image-rendering: pixelated; image-rendering: crisp-edges; }
    code { word-break: break-all; display:block; padding:12px; border:1px solid #ccc; border-radius:8px; background:#f7f7f7; }
    pre { white-space: pre; overflow-x: auto; background:#f7f7f7; border:1px solid #ddd; border-radius:8px; padding:12px; }
  </style>
</head>
<body>
  <div class="wrap">
    <h2>Briar Mailbox</h2>
    <p class="muted">This page refreshes every 2 seconds.</p>

    <h3>QR (exactly from Briar log)</h3>
    <div class="qrframe">
      <img id="qrimg" src="qr.png" alt="QR">
    </div>

    <h3>Desktop link</h3>
    <code id="link">(waiting...)</code>

    <h3>Captured ASCII (for debugging)</h3>
    <pre id="ascii">(waiting...)</pre>

    <script>
      async function refresh() {
        // update link
        try {
          const t = (await (await fetch('mailbox.txt', { cache: 'no-store' })).text()).trim();
          document.getElementById('link').textContent = t || '(waiting...)';
        } catch (e) {
          document.getElementById('link').textContent = '(error loading mailbox.txt)';
        }

        // update ascii
        try {
          const a = await (await fetch('qr_ascii.txt', { cache: 'no-store' })).text();
          document.getElementById('ascii').textContent = a.trim() ? a : '(waiting...)';
        } catch (e) {
          document.getElementById('ascii').textContent = '(error loading qr_ascii.txt)';
        }

        // bust cache for QR image
        document.getElementById('qrimg').src = 'qr.png?t=' + Date.now();
      }
      refresh();
      setInterval(refresh, 2000);
    </script>
  </div>
</body>
</html>
HTML

# Serve /data on 8080 (Ingress-safe)
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

# Start Briar mailbox (log captured)
echo "Starting Briar mailbox..."
java -jar /app/briar-mailbox.jar 2>&1 | tee -a "$LOG" &
BriarPID=$!

extract_ascii_qr() {
  # Extract ONLY the QR block from log into /data/qr_ascii.txt
  # Between:
  #   Please scan this with the Briar Android app:
  # and
  #   Or copy and paste this into Briar Desktop:
  awk '
    BEGIN {in=0}
    /Please scan this with the Briar Android app:/ {in=1; next}
    /Or copy and paste this into Briar Desktop:/ {in=0}
    in==1 {print}
  ' "$LOG" > "$QR_ASCII"

  # Remove totally empty leading/trailing lines
  # (keeps the QR grid intact)
  sed -i '1{/^$/d;}' "$QR_ASCII" 2>/dev/null || true
}

render_ascii_qr_to_png() {
  /opt/venv/bin/python - <<'PY'
from pathlib import Path
from PIL import Image

p = Path("/data/qr_ascii.txt")
txt = p.read_text(encoding="utf-8", errors="ignore").splitlines()

# keep only lines that look like QR rows (contain block chars)
# Briar uses full block █. If anything non-space is present, treat as black.
rows = [r.rstrip("\n") for r in txt if r.strip()]

if not rows:
    Image.new("RGB", (600, 600), "white").save("/data/qr.png")
    raise SystemExit(0)

# Normalize widths
w = max(len(r) for r in rows)
rows = [r.ljust(w, " ") for r in rows]
h = len(rows)

# Scale: pixels per module
scale = 10

# Add quiet zone border (modules)
border = 4

img_w = (w + border*2) * scale
img_h = (h + border*2) * scale

img = Image.new("RGB", (img_w, img_h), "white")
px = img.load()

def is_black(ch: str) -> bool:
    # Briar prints "█" but be tolerant: anything non-space counts as black
    return ch != " "

for y, row in enumerate(rows):
    for x, ch in enumerate(row):
        if is_black(ch):
            x0 = (x + border) * scale
            y0 = (y + border) * scale
            for yy in range(y0, y0 + scale):
                for xx in range(x0, x0 + scale):
                    px[xx, yy] = (0, 0, 0)

img.save("/data/qr.png")
PY
}

echo "Waiting for Briar ASCII QR + mailbox URL..."

MAILBOX_URL=""
FOUND_QR=""

for i in $(seq 1 240); do
  if ! kill -0 "$BriarPID" 2>/dev/null; then
    echo "Briar exited before QR/URL was fully captured."
    break
  fi

  # Extract desktop URL if present
  MAILBOX_URL="$(grep -Eo 'briar-mailbox://[^[:space:]]+' "$LOG" | tail -n 1 || true)"
  if [[ -n "$MAILBOX_URL" ]]; then
    echo "$MAILBOX_URL" > "$QR_TXT"
  fi

  # Extract ASCII QR
  extract_ascii_qr

  # If we have a real-looking QR block (many lines), render it
  if [[ "$(wc -l < "$QR_ASCII" | tr -d ' ')" -ge 20 ]]; then
    render_ascii_qr_to_png
    FOUND_QR="yes"
  fi

  if [[ -n "$MAILBOX_URL" && -n "$FOUND_QR" ]]; then
    echo "Captured URL + rendered ASCII QR."
    break
  fi

  sleep 1
done

echo "Mailbox URL captured: $(cat "$QR_TXT" 2>/dev/null || true)"

wait "$BriarPID"
