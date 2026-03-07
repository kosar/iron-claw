#!/usr/bin/env bash
# Test that the agent's gateway responds to HTTP chat completions.
# Usage: ./scripts/test-gateway-http.sh <agent-name>

set -e
source "$(dirname "$0")/lib.sh"
resolve_agent "$1"; shift

if [[ ! -f "$AGENT_ENV" ]]; then
  echo "No .env file for $AGENT_NAME. Create one with OPENCLAW_GATEWAY_TOKEN=your_token"
  exit 1
fi
# Read token (avoid sourcing .env in case of special chars; token may contain =)
OPENCLAW_GATEWAY_TOKEN=$(grep -E '^OPENCLAW_GATEWAY_TOKEN=' "$AGENT_ENV" 2>/dev/null | cut -d= -f2- | tr -d '"'\''\r' | xargs)
if [[ -z "$OPENCLAW_GATEWAY_TOKEN" ]]; then
  echo "OPENCLAW_GATEWAY_TOKEN not set in $AGENT_ENV"
  exit 1
fi

echo "[$AGENT_NAME] Calling gateway at http://127.0.0.1:${AGENT_PORT}/v1/chat/completions ..."
curl -sS "http://127.0.0.1:${AGENT_PORT}/v1/chat/completions" \
  -H "Authorization: Bearer $OPENCLAW_GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -H "x-openclaw-agent-id: main" \
  -d "{\"model\":\"openclaw\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: ${AGENT_NAME} is working.\"}]}" \
  | head -c 500
echo ""
echo "Done. If you see a JSON response with content, the gateway and agent work."
