#!/usr/bin/env bash
# Trigger host audio bridge to record N seconds from the USB mic. Writes to workspace/audio/last_record.wav.
# Usage: record.sh [seconds]
# Default 10. Max 60. Run from container; bridge must be on Pi host (port 18796).
AUDIO_URL="${AUDIO_BRIDGE_URL:-http://host.docker.internal:18796}"
SECONDS="${1:-10}"
resp=$(curl -sf -m $((SECONDS + 20)) -X POST "$AUDIO_URL/record" \
  -H "Content-Type: application/json" \
  -d "{\"seconds\": $SECONDS}" 2>/dev/null || echo '{"ok":false}')
if echo "$resp" | python3 -c "import json,sys; exit(0 if json.load(sys.stdin).get('ok') else 1)" 2>/dev/null; then
  echo "OK: workspace/audio/last_record.wav"
else
  err=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error','unknown'))" 2>/dev/null)
  echo "RECORD_FAILED: ${err:-bridge unreachable}"
  exit 1
fi
