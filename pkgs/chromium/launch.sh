#!/bin/sh
# Headless chromium daemon. Exposes CDP for the native playwright-mcp to drive.
set -e
CHROME=$(ls /ms-playwright/chromium-*/chrome-linux64/chrome | head -1)
exec "$CHROME" \
  --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
  --remote-debugging-address=0.0.0.0 --remote-debugging-port=9222 \
  --user-agent="$CHROME_UA" \
  --user-data-dir=/tmp/chrome-data about:blank
