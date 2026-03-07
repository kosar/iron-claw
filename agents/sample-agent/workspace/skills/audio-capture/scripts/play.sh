#!/usr/bin/env bash
# Trigger host audio bridge to play a WAV file (path relative to workspace).
# Usage: play.sh <path>
# Example: play.sh rfid/scan_sound.wav   or   play.sh audio/prompt_announce.wav
AUDIO_URL="${AUDIO_BRIDGE_URL:-http://host.docker.internal:18796}"
PATH_ARG="${1:-}"
if [[ -z "$PATH_ARG" ]]; then
  echo "Usage: play.sh <workspace-relative-path>"
  exit 1
fi
# Normalize: if user passed workspace/..., strip prefix for bridge
if [[ "$PATH_ARG" == workspace/* ]]; then
  PATH_ARG="${PATH_ARG#workspace/}"
fi
resp=$(curl -sf -m 15 -X POST "$AUDIO_URL/play" \
  -H "Content-Type: application/json" \
  -d "{\"path\": \"$PATH_ARG\"}" 2>/dev/null || echo '{"ok":false}')
if echo "$resp" | python3 -c "import json,sys; exit(0 if json.load(sys.stdin).get('ok') else 1)" 2>/dev/null; then
  echo "OK: played $PATH_ARG"
else
  echo "PLAY_FAILED"
  exit 1
fi
