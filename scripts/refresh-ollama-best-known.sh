#!/usr/bin/env bash
# refresh-ollama-best-known.sh — Re-run discovery, verify each host with a minimal completion, update workspace/ollama-best-known.json.
# Run on the same schedule as the agent heartbeat (e.g. every 2h) so the agent always has a known-good list.
#
# Usage: ./scripts/refresh-ollama-best-known.sh <agent-name>
# Requires: jq, curl. Writes to agents/<name>/workspace/ollama-best-known.json.

set -e
source "$(dirname "$0")/lib.sh"
resolve_agent "${1:?Usage: $0 <agent-name>}"

OLLAMA_TMP=$(mktemp)
trap 'rm -f "$OLLAMA_TMP"' EXIT

# Run discovery
if ! (bash "$IRONCLAW_ROOT/scripts/discover-ollama.sh" "$OLLAMA_TMP" 2>/dev/null && [[ -s "$OLLAMA_TMP" ]]); then
  echo "[$AGENT_NAME] Discovery failed; leaving existing ollama-best-known.json unchanged." >&2
  exit 0
fi

_now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Verify a host by sending a minimal POST /api/generate (required for "known good")
# Returns 0 if HTTP 200, non-zero otherwise. Uses first text model on the host.
verify_host() {
  local host="$1"
  local port="${2:-11434}"
  local model="$3"
  local url="http://${host}:${port}/api/generate"
  local code
  local body
  body=$(jq -c -n --arg m "$model" '{model:$m,prompt:"hi",stream:false,options:{num_predict:1}}')
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -X POST "$url" \
    -H "Content-Type: application/json" -d "$body")
  [[ "$code" == "200" ]]
}

# Build new hosts array: merge discovery with last_success_at from verification
# Discovery gives .hosts[] with .host, .port, .text_models (raw names), .image_models
# We output same schema as best-known: text_models/vision_models/image_models with "ollama/" prefix, last_probed_at, last_success_at
_hosts_json=$(jq -c --arg now "$_now" '
  [.hosts[] |
    {
      host: .host,
      port: .port,
      last_probed_at: $now,
      last_success_at: null,
      text_models: [.text_models[]? | "ollama/" + .],
      vision_models: [.text_models[]? | select(test("vision"; "i")) | "ollama/" + .],
      image_models: [.image_models[]? | "ollama/" + .],
      _raw_text: (.text_models // [])
    }
  ]
' "$OLLAMA_TMP")

# Per-host verification: for each host, try first text model; set last_success_at on 200
_hosts_verified=()
_count=$(echo "$_hosts_json" | jq 'length')
for i in $(seq 0 $((_count - 1)) 2>/dev/null); do
  [[ "$i" -lt 0 ]] && continue
  _h=$(echo "$_hosts_json" | jq -c ".[$i]")
  _host=$(echo "$_h" | jq -r '.host')
  _port=$(echo "$_h" | jq -r '.port // 11434')
  _first_model=$(echo "$_h" | jq -r '._raw_text[0] // empty')
  _success_at="null"
  if [[ -n "$_first_model" ]]; then
    if verify_host "$_host" "$_port" "$_first_model"; then
      _success_at="\"$_now\""
    fi
  fi
  _h=$(echo "$_h" | jq -c --argjson sa "$_success_at" 'del(._raw_text) | .last_success_at = $sa')
  _hosts_verified+=("$_h")
done

# Build JSON array of verified hosts (bash array to JSON array)
_hosts_final="["
for i in "${!_hosts_verified[@]}"; do
  [[ $i -gt 0 ]] && _hosts_final+=","
  _hosts_final+="${_hosts_verified[$i]}"
done
_hosts_final+="]"

# Prefer first host with last_success_at set; else first host
_chosen=$(echo "$_hosts_final" | jq -r '([.[] | select(.last_success_at != null) | .host][0]) // (.[0].host) // empty')

_tool_raw=$(echo "$_hosts_final" | jq -c --arg ch "$_chosen" '
  [.[] | select(.host == $ch) | .text_models[]? | gsub("ollama/"; "")] |
  map(select(test("^(qwen3|qwen2.5-coder|llama3.2)"; "i") and (test("deepseek-r1"; "i") | not)))
')
_primary=$(echo "$_tool_raw" | jq -r 'if length > 0 then "ollama/" + .[0] else "" end')
_fallbacks=$(echo "$_tool_raw" | jq -c 'if length > 1 then [.[1:][] | "ollama/" + .] else [] end')

_best_known=$(jq -n \
  --arg now "$_now" \
  --arg chosen "$_chosen" \
  --argjson hosts "$_hosts_final" \
  --arg p "$_primary" \
  --argjson fallbacks "$_fallbacks" \
  '{
    updated_at: $now,
    hosts: $hosts,
    source_host: $chosen,
    recommended_primary: (if $p == "" then null else $p end),
    recommended_fallbacks: $fallbacks
  }')

mkdir -p "$AGENT_WORKSPACE"
echo "$_best_known" > "$AGENT_WORKSPACE/ollama-best-known.json"
echo "[$AGENT_NAME] Refreshed workspace/ollama-best-known.json (verified $(echo "$_hosts_final" | jq '[.[] | select(.last_success_at != null)] | length') host(s))" >&2
