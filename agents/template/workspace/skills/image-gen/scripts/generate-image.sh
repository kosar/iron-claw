#!/usr/bin/env bash
# generate-image.sh — Generate an image via Ollama (LAN) or cloud fallback.
# Usage: bash generate-image.sh "prompt text" [output-path]
# Output: Prints the path to the generated PNG, or an error message.
#
# Fallback: stored last host -> catalog -> re-scan LAN -> host.docker.internal -> optional pull -> provider -> DALL-E -> unavailable
# Dependencies: curl, node (for JSON — jq not available in container)

PROMPT="${1:?Usage: generate-image.sh \"prompt\"}"
# Always use a unique filename to prevent stale-file races between requests
OUTPUT="/tmp/generated-$(date +%s)-$$.png"
TIMEOUT=180
PULL_TIMEOUT=600
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOSTS_FILE="$SKILL_DIR/ollama-hosts.json"
LAST_FILE="$SKILL_DIR/ollama-last.json"
SCANNER="$SKILL_DIR/scripts/discover-ollama.sh"

# Preferred image model order: flux2-klein (text/logos), then z-image-turbo (photorealistic)
DEFAULT_MODELS="x/flux2-klein x/z-image-turbo"

# --- JSON helpers using node (available in OpenClaw container) ---
json_escape() {
  node -e "process.stdout.write(JSON.stringify(process.argv[1]))" "$1"
}

json_extract() {
  local keys=""
  for k in "$@"; do keys+="['$k']"; done
  node -e "
    let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
      try {
        const j = JSON.parse(d);
        const v = j${keys};
        if (v !== undefined && v !== null) process.stdout.write(String(v));
      } catch(e) {}
    });
  " 2>/dev/null
}

# Output lines: "host port model1 model2 ..." for each image_capable host (models from catalog, preferred order)
json_extract_hosts_with_models() {
  node -e "
    try {
      const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
      const cap = d.image_capable || [];
      const prefer = ['x/flux2-klein', 'x/z-image-turbo'];
      cap.forEach(h => {
        const models = h.models || [];
        const ordered = [];
        prefer.forEach(p => {
          const m = models.find(n => n === p || n.startsWith(p + ':'));
          if (m) ordered.push(m);
        });
        models.forEach(m => { if (!ordered.includes(m)) ordered.push(m); });
        if (ordered.length === 0) ordered.push('x/flux2-klein', 'x/z-image-turbo');
        console.log([h.host, h.port, ...ordered].join(' '));
      });
    } catch(e) {}
  " "$1" 2>/dev/null
}

# Legacy: host:port only (no model list)
json_extract_hosts() {
  node -e "
    try {
      const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
      (d.image_capable||[]).forEach(h => console.log(h.host+':'+h.port));
    } catch(e) {}
  " "$1" 2>/dev/null
}

# Persist last working Ollama host and model for next run
persist_ollama_last() {
  local HOST="$1" PORT="$2" MODEL="$3"
  local BASE="http://$HOST:$PORT"
  local TS
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  node -e "
    const fs = require('fs');
    const p = process.argv[1];
    const o = { last_ollama_base_url: process.argv[2], last_image_model: process.argv[3], last_success_at: process.argv[4] };
    fs.writeFileSync(p, JSON.stringify(o, null, 2));
  " "$LAST_FILE" "$BASE" "$MODEL" "$TS" 2>/dev/null
}

# --- Try generating on a specific Ollama host; optional third arg = space-separated model list ---
try_ollama_host() {
  local HOST="$1" PORT="$2" MODELS_STR="${3:-$DEFAULT_MODELS}"
  local ESCAPED_PROMPT
  ESCAPED_PROMPT=$(json_escape "$PROMPT")
  local MODEL
  for MODEL in $MODELS_STR; do
    # Ollama /api/generate: model, prompt, stream: false, options: width, height, steps
    local MODEL_ESC
    MODEL_ESC=$(node -e "process.stdout.write(JSON.stringify(process.argv[1]))" "$MODEL" 2>/dev/null) || continue
    local BODY
    BODY="{\"model\":$MODEL_ESC,\"prompt\":$ESCAPED_PROMPT,\"stream\":false,\"options\":{\"width\":1024,\"height\":1024,\"steps\":9}}"
    curl -s --max-time "$TIMEOUT" "http://$HOST:$PORT/api/generate" \
      -H "Content-Type: application/json" \
      -d "$BODY" 2>/dev/null \
    | node -e "
      let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
        try {
          const j = JSON.parse(d);
          const img = j.image || (j.images && j.images[0]) || j.response || '';
          if (img && img.length > 100) {
            require('fs').writeFileSync(process.argv[1], Buffer.from(img, 'base64'));
          }
        } catch(e) {}
      });
    " "$OUTPUT" 2>/dev/null

    if [[ -s "$OUTPUT" ]]; then
      echo "IMAGE_GEN_SOURCE=local OLLAMA_HOST=$HOST MODEL=$MODEL" >&2
      echo "OK:local:$MODEL:$HOST:$OUTPUT"
      persist_ollama_last "$HOST" "$PORT" "$MODEL"
      return 0
    fi
  done
  return 1
}

# --- 0. Try stored last host+model (short-circuit if still reachable) ---
if [[ -f "$LAST_FILE" ]]; then
  BASE_URL=$(node -e "try { const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); process.stdout.write(d.last_ollama_base_url||''); } catch(e) {}" "$LAST_FILE" 2>/dev/null)
  LAST_MODEL=$(node -e "try { const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); process.stdout.write(d.last_image_model||''); } catch(e) {}" "$LAST_FILE" 2>/dev/null)
  if [[ -n "$BASE_URL" && -n "$LAST_MODEL" ]]; then
    # Parse http://host:port
    if [[ "$BASE_URL" =~ ^https?://([^:/]+):([0-9]+) ]]; then
      STORED_HOST="${BASH_REMATCH[1]}" STORED_PORT="${BASH_REMATCH[2]}"
      if curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$BASE_URL/api/tags" 2>/dev/null | grep -q 200; then
        TAGS=$(curl -s --max-time 5 "$BASE_URL/api/tags" 2>/dev/null)
        if node -e "
          const tags = JSON.parse(process.argv[1]);
          const name = process.argv[2];
          const has = (tags.models || []).some(m => m.name === name || (m.name && m.name.startsWith(name.split(':')[0] + ':')));
          process.exit(has ? 0 : 1);
        " "$TAGS" "$LAST_MODEL" 2>/dev/null; then
          if try_ollama_host "$STORED_HOST" "$STORED_PORT" "$LAST_MODEL"; then
            exit 0
          fi
        fi
      fi
    fi
  fi
fi

# --- 1. Try known Ollama hosts from catalog (with their image models) ---
if [[ -f "$HOSTS_FILE" ]]; then
  while read -r line; do
    [[ -z "$line" ]] && continue
    arr=($line)
    HOST="${arr[0]}" PORT="${arr[1]}"
    MODELS="${arr[*]:2}"
    [[ -z "$MODELS" ]] && MODELS="$DEFAULT_MODELS"
    if curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://$HOST:$PORT/api/version" 2>/dev/null | grep -q 200; then
      try_ollama_host "$HOST" "$PORT" "$MODELS" && exit 0
    fi
  done < <(json_extract_hosts_with_models "$HOSTS_FILE")
  # Fallback: try catalog hosts with default model list (in case catalog format differs)
  HOSTS=$(json_extract_hosts "$HOSTS_FILE")
  for HP in $HOSTS; do
    HOST="${HP%%:*}" PORT="${HP##*:}"
    if curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://$HOST:$PORT/api/version" 2>/dev/null | grep -q 200; then
      try_ollama_host "$HOST" "$PORT" "" && exit 0
    fi
  done
fi

# --- 2. Re-scan LAN and retry ---
if [[ -x "$SCANNER" ]]; then
  bash "$SCANNER" "$HOSTS_FILE" 2>/dev/null
  if [[ -f "$HOSTS_FILE" ]]; then
    while read -r line; do
      [[ -z "$line" ]] && continue
      arr=($line)
      HOST="${arr[0]}" PORT="${arr[1]}"
      MODELS="${arr[*]:2}"
      [[ -z "$MODELS" ]] && MODELS="$DEFAULT_MODELS"
      if curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://$HOST:$PORT/api/version" 2>/dev/null | grep -q 200; then
        try_ollama_host "$HOST" "$PORT" "$MODELS" && exit 0
      fi
    done < <(json_extract_hosts_with_models "$HOSTS_FILE")
    HOSTS=$(json_extract_hosts "$HOSTS_FILE")
    for HP in $HOSTS; do
      HOST="${HP%%:*}" PORT="${HP##*:}"
      if curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://$HOST:$PORT/api/version" 2>/dev/null | grep -q 200; then
        try_ollama_host "$HOST" "$PORT" "" && exit 0
      fi
    done
  fi
fi

# --- 3. Try host.docker.internal ---
DOCKER_HOST="host.docker.internal"
if curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://$DOCKER_HOST:11434/api/version" 2>/dev/null | grep -q 200; then
  try_ollama_host "$DOCKER_HOST" "11434" "" && exit 0
fi

# --- 4. Optional: no image model on any host — try pull on localhost then retry ---
PULL_HOST="$DOCKER_HOST"
PULL_PORT="11434"
if curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://$PULL_HOST:$PULL_PORT/api/version" 2>/dev/null | grep -q 200; then
  PULL_OUT=$(curl -s --max-time "$PULL_TIMEOUT" "http://$PULL_HOST:$PULL_PORT/api/pull" \
    -H "Content-Type: application/json" \
    -d '{"model":"x/flux2-klein","stream":false}' 2>/dev/null)
  if echo "$PULL_OUT" | grep -qE '"status"\s*:\s*"success"'; then
    try_ollama_host "$PULL_HOST" "$PULL_PORT" "x/flux2-klein" && exit 0
  fi
fi

# --- 5. Provider image model (if configured) ---
if [[ -n "$MODEL_PROVIDER_IMAGE_URL" && -n "$MODEL_PROVIDER_IMAGE_KEY" ]]; then
  ESCAPED_PROMPT=$(json_escape "$PROMPT")
  RESPONSE=$(curl -s --max-time $TIMEOUT "$MODEL_PROVIDER_IMAGE_URL" \
    -H "Authorization: Bearer $MODEL_PROVIDER_IMAGE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"prompt\":$ESCAPED_PROMPT,\"n\":1,\"size\":\"1024x1024\"}" 2>/dev/null)
  IMAGE_URL=$(node -e "
    try {
      const d = JSON.parse(process.argv[1]);
      const v = d.data && d.data[0] && (d.data[0].url || d.data[0].b64_json);
      if (v) process.stdout.write(v);
    } catch(e) {}
  " "$RESPONSE" 2>/dev/null)
  if [[ -n "$IMAGE_URL" && "$IMAGE_URL" != "null" ]]; then
    if [[ "$IMAGE_URL" =~ ^http ]]; then
      curl -s "$IMAGE_URL" -o "$OUTPUT" 2>/dev/null
    else
      echo "$IMAGE_URL" | base64 -d > "$OUTPUT" 2>/dev/null
    fi
    if [[ -s "$OUTPUT" ]]; then
      echo "IMAGE_GEN_SOURCE=provider" >&2
      echo "OK:provider:$OUTPUT"
      exit 0
    fi
  fi
fi

# --- 6. OpenAI DALL-E (fallback only after local exhausted) ---
if [[ -n "$OPENAI_API_KEY" ]]; then
  ESCAPED_PROMPT=$(json_escape "$PROMPT")
  RESPONSE=$(curl -s --max-time 60 "https://api.openai.com/v1/images/generations" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"dall-e-3\",\"prompt\":$ESCAPED_PROMPT,\"n\":1,\"size\":\"1024x1024\"}" 2>/dev/null)
  IMAGE_URL=$(node -e "
    try {
      const d = JSON.parse(process.argv[1]);
      const v = d.data && d.data[0] && d.data[0].url;
      if (v) process.stdout.write(v);
    } catch(e) {}
  " "$RESPONSE" 2>/dev/null)
  if [[ -n "$IMAGE_URL" && "$IMAGE_URL" != "null" ]]; then
    curl -s "$IMAGE_URL" -o "$OUTPUT" 2>/dev/null
    if [[ -s "$OUTPUT" ]]; then
      echo "IMAGE_GEN_SOURCE=dalle" >&2
      echo "OK:dalle:$OUTPUT"
      exit 0
    fi
  fi
fi

# --- 7. Nothing available ---
echo "UNAVAILABLE: Image generation is not available. To enable:"
echo "  - Local: Install Ollama with image models on any LAN machine (ollama pull x/flux2-klein)"
echo "  - Cloud: Add OPENAI_API_KEY to your .env for DALL-E fallback"
echo "  - Re-scan: bash $SCANNER $HOSTS_FILE"
exit 1
