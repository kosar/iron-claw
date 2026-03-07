#!/usr/bin/env bash
# describe-image.sh — Describe an image using LAN Ollama vision (llama3.2-vision:latest).
# Usage: bash describe-image.sh <image-path> [question]
# Output: Prints the description to stdout, or an error line to stderr and exits non-zero.
# Discovery: OLLAMA_HOST -> last host -> ollama-hosts.json -> re-scan LAN -> host.docker.internal
# Dependencies: curl, node, python3 (no jq in container)

IMAGE_PATH="${1:?Usage: describe-image.sh <image-path> [question]}"
QUESTION="${2:-Describe this image.}"
TIMEOUT=120
VISION_MODEL="llama3.2-vision:latest"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOSTS_FILE="$SKILL_DIR/ollama-hosts.json"
LAST_FILE="$SKILL_DIR/ollama-last.json"
SCANNER="$SKILL_DIR/scripts/discover-ollama.sh"
# Log when we run (container logs dir = /tmp/openclaw; mounted from agents/pibot/logs)
MEDIA_VISION_LOG="${OPENCLAW_LOG_DIR:-/tmp/openclaw}/media-vision.log"

if [[ ! -f "$IMAGE_PATH" ]]; then
  echo "ERROR: Image file not found: $IMAGE_PATH" >&2
  exit 1
fi

# Visibility: log start so watch-logs / operator can see media understanding ran
printf '%s\tstart\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$IMAGE_PATH" >> "$MEDIA_VISION_LOG" 2>/dev/null || true

# Build request body JSON to a temp file (avoids ARG_MAX with large base64)
BODY_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE"' EXIT
node -e "
  const fs = require('fs');
  const imgPath = process.argv[1];
  const question = process.argv[2];
  const outPath = process.argv[3];
  const b64 = fs.readFileSync(imgPath, { encoding: null }).toString('base64').replace(/\n/g, '');
  const body = JSON.stringify({ model: 'llama3.2-vision:latest', messages: [{ role: 'user', content: question, images: [b64] }], stream: false });
  fs.writeFileSync(outPath, body);
" "$IMAGE_PATH" "$QUESTION" "$BODY_FILE" 2>/dev/null || { echo "ERROR: Failed to build request body" >&2; exit 1; }

# Call Ollama /api/chat with curl; parse message.content with node
try_host() {
  local HOST="$1" PORT="${2:-11434}"
  local URL="http://$HOST:$PORT/api/chat"
  local RES
  RES=$(curl -s --max-time "$TIMEOUT" -X POST "$URL" -H "Content-Type: application/json" -d @"$BODY_FILE" 2>/dev/null | node -e "
    let d = '';
    process.stdin.on('data', c => d += c);
    process.stdin.on('end', () => {
      try {
        const j = JSON.parse(d);
        const content = j.message && j.message.content;
        if (content) process.stdout.write(content);
      } catch (e) {}
    });
  " 2>/dev/null)
  if [[ -n "$RES" ]]; then
    echo "$RES"
    node -e "
      const fs = require('fs');
      fs.writeFileSync(process.argv[1], JSON.stringify({ last_ollama_base_url: process.argv[2], last_vision_model: 'llama3.2-vision:latest', last_success_at: new Date().toISOString() }, null, 2));
    " "$LAST_FILE" "http://$HOST:$PORT" 2>/dev/null
    printf '%s\tok\t%s:%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$HOST" "$PORT" "$IMAGE_PATH" >> "$MEDIA_VISION_LOG" 2>/dev/null || true
    return 0
  fi
  return 1
}

# --- 0. OLLAMA_HOST (from compose / LAN discovery) ---
if [[ -n "$OLLAMA_HOST" ]]; then
  O_HOST="${OLLAMA_HOST%%:*}"
  O_PORT="${OLLAMA_HOST##*:}"
  [[ "$O_PORT" == "$O_HOST" ]] && O_PORT="11434"
  if try_host "$O_HOST" "$O_PORT"; then exit 0; fi
fi

# --- 1. Last used host ---
if [[ -f "$LAST_FILE" ]]; then
  BASE_URL=$(node -e "try { const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); process.stdout.write(d.last_ollama_base_url||''); } catch(e) {}" "$LAST_FILE" 2>/dev/null)
  if [[ -n "$BASE_URL" && "$BASE_URL" =~ ^https?://([^:/]+):([0-9]+) ]]; then
  STORED_HOST="${BASH_REMATCH[1]}" STORED_PORT="${BASH_REMATCH[2]}"
  if try_host "$STORED_HOST" "$STORED_PORT"; then exit 0; fi
  fi
fi

# --- 2. Catalog (ollama-hosts.json): try .hosts ---
if [[ -f "$HOSTS_FILE" ]]; then
  while read -r line; do
    [[ -z "$line" ]] && continue
    arr=($line)
    HOST="${arr[0]}" PORT="${arr[1]:-11434}"
    if try_host "$HOST" "$PORT"; then exit 0; fi
  done < <(node -e "
    try {
      const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
      (d.hosts||[]).forEach(h => console.log(h.host, h.port||11434));
    } catch(e) {}
  " "$HOSTS_FILE" 2>/dev/null)
fi

# --- 3. Re-scan LAN and retry ---
if [[ -x "$SCANNER" ]]; then
  bash "$SCANNER" "$HOSTS_FILE" 2>/dev/null
  if [[ -f "$HOSTS_FILE" ]]; then
    while read -r line; do
      [[ -z "$line" ]] && continue
      arr=($line)
      HOST="${arr[0]}" PORT="${arr[1]:-11434}"
      if try_host "$HOST" "$PORT"; then exit 0; fi
    done < <(node -e "
      try {
        const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
        (d.hosts||[]).forEach(h => console.log(h.host, h.port||11434));
      } catch(e) {}
    " "$HOSTS_FILE" 2>/dev/null)
  fi
fi

# --- 4. host.docker.internal ---
if try_host "host.docker.internal" "11434"; then exit 0; fi

printf '%s\tunavailable\t\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$IMAGE_PATH" >> "$MEDIA_VISION_LOG" 2>/dev/null || true
echo "UNAVAILABLE: No Ollama vision model (llama3.2-vision:latest) reachable. Install on LAN: ollama pull llama3.2-vision:latest" >&2
exit 1
