#!/usr/bin/env bash
# piface-startup: Send the "Startup Ritual" banner to the PiFace LCD
# This banner will stay on for 5 minutes.
# Use: bash startup.sh "Line 1" "Line 2"

L1="${1:-PiBot ONLINE}"
L2="${2:-Ready & Aware}"

PIFACE_URL="${PIFACE_DISPLAY_URL:-http://host.docker.internal:18794/display}"

# Send update to the bridge on the host with the 'startup' flag
curl -sf -m 3 -G \
  --data-urlencode "l1=$L1" \
  --data-urlencode "l2=$L2" \
  --data-urlencode "startup=1" \
  "${PIFACE_URL}" >/dev/null 2>/dev/null || true

exit 0
