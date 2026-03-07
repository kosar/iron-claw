#!/usr/bin/env bash
# Test that the pibot gateway accepts POST /hooks/agent (RFID notification path).
# Usage: ./scripts/test-rfid-hook.sh
# Run from repo root on the Pi (or wherever pibot runs). Prints HTTP status and body.
set -e
source "$(dirname "$0")/lib.sh"
resolve_agent "pibot"

if [[ ! -f "$AGENT_ENV" ]]; then
  echo "No .env at $AGENT_ENV. Set OPENCLAW_HOOKS_TOKEN or OPENCLAW_GATEWAY_TOKEN there." >&2
  exit 1
fi
HOOKS_TOKEN=$(grep -E '^OPENCLAW_HOOKS_TOKEN=' "$AGENT_ENV" 2>/dev/null | cut -d= -f2- | tr -d '"'\''\r' | xargs)
[[ -z "$HOOKS_TOKEN" ]] && HOOKS_TOKEN=$(grep -E '^OPENCLAW_GATEWAY_TOKEN=' "$AGENT_ENV" 2>/dev/null | cut -d= -f2- | tr -d '"'\''\r' | xargs)
if [[ -z "$HOOKS_TOKEN" ]]; then
  echo "OPENCLAW_HOOKS_TOKEN and OPENCLAW_GATEWAY_TOKEN not set in $AGENT_ENV" >&2
  exit 1
fi

CHAT_ID=$(jq -r '.channels.telegram.allowFrom[0] // empty' "$AGENT_CONFIG/openclaw.json" 2>/dev/null)
if [[ -z "$CHAT_ID" ]]; then
  echo "Could not read Telegram allowFrom from $AGENT_CONFIG/openclaw.json" >&2
  exit 1
fi

echo "[pibot] POST /hooks/agent (deliver to Telegram chat $CHAT_ID)..."
resp=$(curl -sS -w "\n%{http_code}" -X POST "http://127.0.0.1:${AGENT_PORT}/hooks/agent" \
  -H "Authorization: Bearer $HOOKS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"message\":\"RFID test: manual trigger. Reply with: RFID hook works.\",\"name\":\"RFID\",\"agentId\":\"main\",\"wakeMode\":\"now\",\"deliver\":true,\"channel\":\"telegram\",\"to\":\"$CHAT_ID\",\"timeoutSeconds\":90}")
body=$(echo "$resp" | head -n -1)
code=$(echo "$resp" | tail -n 1)
echo "HTTP $code"
echo "$body" | head -c 500
echo ""
if [[ "$code" == "202" ]]; then
  echo "OK: Hook accepted (202). Check Telegram for the bot reply in ~30–60s."
elif [[ "$code" == "401" ]]; then
  echo "FAIL: 401 Unauthorized. Ensure OPENCLAW_HOOKS_TOKEN in .env matches hooks.token in config and is different from OPENCLAW_GATEWAY_TOKEN."
elif [[ "$code" == "404" ]]; then
  echo "FAIL: 404. Hooks may be disabled. Check agents/pibot/config/openclaw.json has hooks.enabled: true and path: \"/hooks\"."
elif [[ "$code" == "000" ]]; then
  echo "FAIL: No response (connection reset or refused). Check gateway started: docker logs pibot_secure 2>&1 | tail -5. If you see 'hooks.token must not match gateway auth token', set OPENCLAW_HOOKS_TOKEN to a different value than OPENCLAW_GATEWAY_TOKEN (e.g. openssl rand -hex 32) and restart compose."
else
  echo "Unexpected status. Check gateway logs: docker logs pibot_secure 2>&1 | tail -50"
fi
