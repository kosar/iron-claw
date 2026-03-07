#!/usr/bin/env bash
# probe-gateway.sh — Test agent gateway HTTP (JSON). For ironclaw dashboard.
# Usage: IRONCLAW_ROOT=/path AGENT_NAME=pibot ./probe-gateway.sh
# Output: JSON to stdout (no secrets)

set -e
ROOT="${IRONCLAW_ROOT:?IRONCLAW_ROOT required}"
AGENT="${AGENT_NAME:?AGENT_NAME required}"
CONF="$ROOT/agents/$AGENT/agent.conf"
ENV_FILE="$ROOT/agents/$AGENT/.env"

if [[ ! -f "$CONF" ]]; then
  echo '{"ok":false,"agent":"'"$AGENT"'","error":"agent not found"}'
  exit 0
fi
source "$CONF"
# AGENT_PORT now set

if [[ ! -f "$ENV_FILE" ]]; then
  echo '{"ok":false,"agent":"'"$AGENT"'","error":"no .env file"}'
  exit 0
fi
TOKEN=$(grep -E '^OPENCLAW_GATEWAY_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"'\''\r' | xargs)
if [[ -z "$TOKEN" ]]; then
  echo '{"ok":false,"agent":"'"$AGENT"'","error":"OPENCLAW_GATEWAY_TOKEN not set"}'
  exit 0
fi

# Lightweight health: GET root with auth. Do NOT POST to /v1/chat/completions here —
# that would create a full agent run (webchat session, PiFace/PiGlow, LLM) every dashboard refresh.
STATUS="fail"
CODE=""
MSG=""
RESP=$(curl -sS -w "\n%{http_code}" -m 5 \
  "http://127.0.0.1:${AGENT_PORT}/" \
  -H "Authorization: Bearer $TOKEN" 2>/dev/null) || true
if [[ -n "$RESP" ]]; then
  CODE=$(echo "$RESP" | tail -1)
  # 000 = curl connection failed/timeout; any other HTTP code means gateway is up
  if [[ "$CODE" =~ ^[0-9]+$ ]] && [[ "$CODE" != "000" ]]; then
    STATUS="ok"
    MSG="gateway responding"
  else
    MSG="${CODE:-connection failed}"
  fi
else
  MSG="connection failed"
fi
echo '{"ok":'"$( [[ "$STATUS" == "ok" ]] && echo true || echo false )"',"agent":"'"$AGENT"'","statusCode":"'"$CODE"'","message":"'"${MSG//\"/\\\"}"'"}'
