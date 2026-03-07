#!/bin/bash
# send-photo.sh — Send a photo to Telegram via openclaw CLI
# Usage: send-photo.sh <image-path-or-url> [caption]
# Accepts both local file paths (/tmp/image.png) and URLs (https://...)
# Captions should be plain text — no HTML tags (Telegram renders them as-is).
#
# NOTE: Update the target (-t) to your Telegram chat ID.

IMAGE="$(echo "$1" | tr -d '\n\r\t ')"
CAPTION="${2:-}"

if [ -z "$IMAGE" ]; then
  echo "error: no image path or URL provided"
  echo "usage: send-photo.sh <path-or-url> [caption]"
  exit 1
fi

# Strip HTML tags from caption (Telegram shows them as raw text otherwise)
if [ -n "$CAPTION" ]; then
  CAPTION=$(echo "$CAPTION" | sed 's/<[^>]*>//g')
fi

openclaw message send --channel telegram -t {{TELEGRAM_CHAT_ID}} --media "$IMAGE" --message "$CAPTION"
