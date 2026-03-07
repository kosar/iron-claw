#!/usr/bin/env bash
# probe-logs.sh — Last N lines of agent app log (JSON). For ironclaw dashboard.
# Usage: IRONCLAW_ROOT=/path AGENT_NAME=pibot N=50 ./probe-logs.sh
# Output: JSON to stdout

set -e
ROOT="${IRONCLAW_ROOT:?IRONCLAW_ROOT required}"
AGENT="${AGENT_NAME:?AGENT_NAME required}"
N="${N:-50}"
LOG_DIR="$ROOT/agents/$AGENT/logs"
LATEST=$(ls -t "$LOG_DIR"/openclaw-*.log 2>/dev/null | head -1)

if [[ -z "$LATEST" || ! -f "$LATEST" ]]; then
  echo '{"ok":false,"agent":"'"$AGENT"'","error":"no openclaw log file","lines":[]}'
  exit 0
fi

# Output JSON: array of { time, level, msg } (parse JSONL with python)
python3 - "$LATEST" "$N" "$AGENT" << 'PY'
import os
import json
import sys
path = sys.argv[1]
n = int(sys.argv[2])
agent = sys.argv[3]
lines = []
try:
    with open(path) as f:
        raw = f.readlines()
    for line in raw[-n:]:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
            msg = o.get("1") or o.get("0") or o.get("message") or str(o)
            if isinstance(msg, dict):
                msg = json.dumps(msg)[:300]
            time = o.get("time") or o.get("_meta", {}).get("date") or ""
            level = (o.get("_meta") or {}).get("logLevelName") or ""
            lines.append({"time": time, "level": level, "msg": str(msg)[:500]})
        except (json.JSONDecodeError, TypeError):
            lines.append({"time": "", "level": "", "msg": line[:500]})
except Exception as e:
    print(json.dumps({"ok": False, "agent": agent, "error": str(e), "lines": []}))
    sys.exit(0)
print(json.dumps({"ok": True, "agent": agent, "file": os.path.basename(path), "lines": lines}))
PY
