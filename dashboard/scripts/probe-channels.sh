#!/usr/bin/env bash
# probe-channels.sh — Channel info for an agent (e.g. Telegram bot @username). JSON only, no secrets.
# Usage: IRONCLAW_ROOT=/path AGENT_NAME=pibot ./probe-channels.sh

set -e
ROOT="${IRONCLAW_ROOT:?IRONCLAW_ROOT required}"
AGENT="${AGENT_NAME:?AGENT_NAME required}"
ENV_FILE="$ROOT/agents/$AGENT/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo '{"ok":true,"agent":"'"$AGENT"'","telegram":null,"error":"no .env"}'
  exit 0
fi

TOKEN=$(grep -E '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"'\''\r' | xargs)
if [[ -z "$TOKEN" ]]; then
  echo '{"ok":true,"agent":"'"$AGENT"'","telegram":null,"error":"no TELEGRAM_BOT_TOKEN"}'
  exit 0
fi

# Telegram getMe: returns bot username and first_name; we never echo token
RESP=$(curl -sS -m 5 "https://api.telegram.org/bot${TOKEN}/getMe" 2>/dev/null) || true
if [[ -z "$RESP" ]]; then
  echo '{"ok":true,"agent":"'"$AGENT"'","telegram":null,"error":"getMe failed"}'
  exit 0
fi

# Parse with python to avoid jq dependency; output only username and first_name
python3 - "$AGENT" "$RESP" << 'PY'
import json
import sys
agent = sys.argv[1]
raw = sys.argv[2]
try:
    data = json.loads(raw)
    if not data.get("ok"):
        print(json.dumps({"ok": True, "agent": agent, "telegram": None, "error": "Telegram API error"}))
        sys.exit(0)
    r = data.get("result") or {}
    username = r.get("username") or ""
    first_name = r.get("first_name") or ""
    if username:
        print(json.dumps({
            "ok": True,
            "agent": agent,
            "telegram": {"username": username, "firstName": first_name},
            "error": None,
        }))
    else:
        print(json.dumps({"ok": True, "agent": agent, "telegram": None, "error": "no username in getMe"}))
except (json.JSONDecodeError, IndexError) as e:
    print(json.dumps({"ok": True, "agent": agent, "telegram": None, "error": "parse failed"}))
PY
