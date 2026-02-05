#!/usr/bin/with-contenv bash
set -euo pipefail

DATA_DIR="/data"
QR_PNG="${DATA_DIR}/qr.png"
QR_TXT="${DATA_DIR}/mailbox.txt"
LOG="/tmp/briar.log"
INDEX="${DATA_DIR}/index.html"

mkdir -p "$DATA_DIR"
: > "$LOG"

# Start Briar mailbox and tee output so we can parse it
java -jar /app/briar-mailbox.jar 2>&1 | tee "$LOG" &
BriarPID=$!

# Wait until the briar-mailbox:// line appears
echo "Waiting for briar-mailbox URL..."
for i in $(seq 1 180); do
  if grep -qE '^briar-mailbox://' "$LOG"; then
    break
  fi
  sleep 1
done

MAILBOX_URL="$(grep -E '^briar-mailbox://' "$LOG" | tail -n 1 || true)"

if [[ -z "${MAILBOX_URL}" ]]; then
  echo "Could not find briar-mailbox URL in logs."
  echo "Last 200 lines:"
  tail -n 200 "$LOG" || true
else
  echo "${MAILBOX_URL}" > "${QR_TXT}"
  echo "Mailbox URL captured: ${MAILBOX_URL}"

  # Generate QR PNG using the venv python (has qrcode + pillow)
  python - <<'PY'
import qrcode, pathlib
txt = pathlib.Path("/data/mailbox.txt").read_text().strip()
img = qrcode.make(txt)
img.save("/data/qr.png")
PY
fi

# Create a tiny HTML page in /data so the same server can serve everything
cat > "$INDEX" <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>Briar Mailbox QR</title>
  <style>
    body { font-family: sans-serif; padding: 16px; }
    .wrap { max-width: 520px; margin: 0 auto; }
    img { width: 100%; height: auto; image-rendering: crisp-edges; background: #fff; padding: 12px; border-radius: 12px; }
    code { word-break: break-all; display:block; padding: 12px; border: 1px solid #ccc; border-radius: 8px; }
  </style>
</head>
<body>
  <div class="wrap">
    <h2>Briar Mailbox</h2>
    <p>Scan this QR in Briar Desktop or copy the link below.</p>
    <p><img src="/qr.png" alt="QR"/></p>
    <h3>Copy/paste link</h3>
    <code id="link">Loading…</code>
    <script>
      fetch('/mailbox.txt').then(r => r.text()).then(t => {
        document.getElementById('link').textContent = t.trim() || '(no link found yet)';
      }).catch(() => {
        document.getElementById('link').textContent = '(could not load mailbox.txt)';
      });
    </script>
  </div>
</body>
</html>
HTML

# Serve /data on 8080 for HA Ingress
cd "$DATA_DIR"
python -m http.server 8080 --bind 0.0.0.0 >/dev/null 2>&1 &
WebPID=$!

# Keep container alive as long as Briar is alive
wait $BriarPID
