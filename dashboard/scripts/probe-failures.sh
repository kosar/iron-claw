#!/usr/bin/env bash
# probe-failures.sh — Failure summary from agent log (JSON). For ironclaw dashboard.
# Usage: IRONCLAW_ROOT=/path AGENT_NAME=pibot ./probe-failures.sh
# Scans last 500 log lines for failure patterns and returns counts by category.

set -e
ROOT="${IRONCLAW_ROOT:?IRONCLAW_ROOT required}"
AGENT="${AGENT_NAME:?AGENT_NAME required}"
LOG_DIR="$ROOT/agents/$AGENT/logs"
LATEST=$(ls -t "$LOG_DIR"/openclaw-*.log 2>/dev/null | head -1)

if [[ -z "$LATEST" || ! -f "$LATEST" ]]; then
  echo '{"ok":true,"agent":"'"$AGENT"'","summary":{"auth":0,"tool":0,"network":0,"provider":0,"error":0,"other":0},"sample":[]}'
  exit 0
fi

python3 - "$LATEST" "$AGENT" << 'PY'
import json
import re
import sys

path = sys.argv[1]
agent = sys.argv[2]
PAT_AUTH = re.compile(r'API key|api key|apiKey|missing.*key|unauthorized|401|403|authentication|auth failed|invalid.*token', re.I)
PAT_TOOL = re.compile(r'tool.*fail|action.*fail|skill.*fail|not configured|not available|missing config', re.I)
PAT_NETWORK = re.compile(r'ECONNREFUSED|ETIMEDOUT|ENOTFOUND|timeout|connection refused|network error|fetch failed', re.I)
PAT_PROVIDER = re.compile(r'openai.*error|ollama.*error|rate limit|429|model.*unavailable|provider.*fail', re.I)
PAT_ERROR = re.compile(r'\berror\b|Error|exception|failed|Failure|ECONNREFUSED|ETIMEDOUT', re.I)

summary = {"auth": 0, "tool": 0, "network": 0, "provider": 0, "error": 0, "other": 0}
sample = []
try:
    with open(path) as f:
        lines = f.readlines()
    for line in lines[-500:]:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
            msg = str(o.get("1") or o.get("0") or o.get("message") or o)
        except (json.JSONDecodeError, TypeError):
            msg = line
        if not msg or len(msg) < 5:
            continue
        cat = None
        if PAT_AUTH.search(msg):    cat = "auth"
        elif PAT_TOOL.search(msg):  cat = "tool"
        elif PAT_NETWORK.search(msg): cat = "network"
        elif PAT_PROVIDER.search(msg): cat = "provider"
        elif PAT_ERROR.search(msg): cat = "error"
        else:                       cat = "other"
        summary[cat] = summary.get(cat, 0) + 1
        if len(sample) < 5:
            time = o.get("time", "") if isinstance(o, dict) else ""
            sample.append({"time": time, "cat": cat, "msg": msg[:200]})
    # sample in reverse so most recent first
    sample = sample[-5:][::-1]
except Exception as e:
    print(json.dumps({"ok": False, "agent": agent, "error": str(e), "summary": summary, "sample": []}))
    sys.exit(0)
print(json.dumps({"ok": True, "agent": agent, "summary": summary, "sample": sample}))
PY
