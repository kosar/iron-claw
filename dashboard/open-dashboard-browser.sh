#!/usr/bin/env bash
# Open the ironclaw dashboard in the default browser after the server is up.
# Used by desktop autostart so the dashboard is the first page on Pi login.
# Waits for http://127.0.0.1:18795/ (or IRONCLAW_DASHBOARD_PORT), then xdg-open.
# Fails quietly if server never responds (e.g. dashboard not enabled).

PORT="${IRONCLAW_DASHBOARD_PORT:-18795}"
URL="http://127.0.0.1:${PORT}/"
MAX_TRIES=3
SLEEP=5

for i in $(seq 1 "$MAX_TRIES"); do
  if curl -sf -m 2 -o /dev/null "$URL" 2>/dev/null; then
    xdg-open "$URL" 2>/dev/null || true
    exit 0
  fi
  [[ $i -lt $MAX_TRIES ]] && sleep "$SLEEP"
done
exit 0
