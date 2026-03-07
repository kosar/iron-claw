#!/usr/bin/env bash
# One-shot: trigger host capture, then send workspace/camera/latest.jpg to Telegram.
# Run from inside the container. Ensures both steps run so the agent cannot skip sending.
set -euo pipefail
CAPTURE_URL="${1:-http://host.docker.internal:18792/capture}"
IMAGE_PATH="/home/ai_sandbox/.openclaw/workspace/camera/latest.jpg"
SEND_PHOTO="/home/ai_sandbox/.openclaw/workspace/scripts/send-photo.sh"

resp=$(curl -sf -m 15 -X POST "$CAPTURE_URL" 2>/dev/null || echo '{"ok":false}')
if ! echo "$resp" | python3 -c "import json,sys; exit(0 if json.load(sys.stdin).get('ok') else 1)" 2>/dev/null; then
  echo "CAPTURE_FAILED"
  exit 1
fi
if [[ ! -f "$IMAGE_PATH" ]]; then
  echo "NO_IMAGE"
  exit 1
fi
exec bash "$SEND_PHOTO" "$IMAGE_PATH" "Photo from camera"
