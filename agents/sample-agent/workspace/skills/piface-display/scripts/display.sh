#!/usr/bin/env bash
# piface-display: update the PiFace LCD display via curl to host port 18794
# Use: bash display.sh "Line 1 text" "Line 2 text" [backlight]
# On failure: logs to stderr and to /tmp/openclaw/piface-display-failures.log so we know the container cannot reach the PiFace bridge.

L1="${1:-}"
L2="${2:-}"
BL="${3:-1}"

PIFACE_URL="${PIFACE_DISPLAY_URL:-http://host.docker.internal:18794/display}"
FAIL_LOG="/tmp/openclaw/piface-display-failures.log"

# Send update to the bridge on the host
if curl -sf -m 3 -G \
  --data-urlencode "l1=$L1" \
  --data-urlencode "l2=$L2" \
  --data-urlencode "backlight=$BL" \
  "${PIFACE_URL}" >/dev/null 2>/dev/null; then
    echo '{"status": "ok", "message": "PiFace display updated successfully."}'
else
    # Instrumentation: so we know the container tried but cannot reach PiFace (network/bridge down)
    ts=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
    msg="PIFACE_UNREACHABLE container could not reach PiFace bridge url=${PIFACE_URL} at ${ts}"
    echo "piface-display: $msg" >&2
    [[ -w "$FAIL_LOG" || -w "$(dirname "$FAIL_LOG")" ]] 2>/dev/null && echo "$msg" >> "$FAIL_LOG"
    echo '{"status": "error", "message": "Could not reach the PiFace bridge on the host."}'
fi

exit 0
