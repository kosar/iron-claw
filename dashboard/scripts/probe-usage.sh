#!/usr/bin/env bash
# probe-usage.sh — Token/cost summary for agent (JSON). For ironclaw dashboard.
# Usage: IRONCLAW_ROOT=/path AGENT_NAME=pibot ./probe-usage.sh

set -e
ROOT="${IRONCLAW_ROOT:?IRONCLAW_ROOT required}"
AGENT="${AGENT_NAME:?AGENT_NAME required}"
SESSIONS="$ROOT/agents/$AGENT/config-runtime/agents/main/sessions"

python3 - "$SESSIONS" "$AGENT" << 'PY'
import json
import os
import sys

sessions_dir = sys.argv[1]
agent = sys.argv[2]
turns = tokens_in = tokens_out = 0
cost_total = 0.0

if os.path.isdir(sessions_dir):
    for f in os.listdir(sessions_dir):
        if not f.endswith(".jsonl"):
            continue
        path = os.path.join(sessions_dir, f)
        try:
            with open(path) as fp:
                for line in fp:
                    try:
                        o = json.loads(line.strip())
                    except json.JSONDecodeError:
                        continue
                    msg = o.get("message") or {}
                    if msg.get("role") != "assistant":
                        continue
                    turns += 1
                    u = msg.get("usage") or {}
                    tokens_in += int(u.get("input") or 0)
                    tokens_out += int(u.get("output") or 0)
                    c = (u.get("cost") or {}).get("total")
                    if c is not None:
                        cost_total += float(c)
        except (IOError, OSError):
            pass

cost_usd = "%.4f" % cost_total if cost_total else None
print(json.dumps({
    "ok": True,
    "agent": agent,
    "turns": turns,
    "tokensIn": tokens_in,
    "tokensOut": tokens_out,
    "costUsd": cost_usd,
}))
PY
