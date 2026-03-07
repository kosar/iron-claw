#!/usr/bin/env bash
# Show recent OpenClaw app log activity for a specific agent.
# Usage: ./scripts/check-logs.sh <agent-name> [N]   — show last N lines (default 50). Use "follow" to tail -f.

set -e
source "$(dirname "$0")/lib.sh"
resolve_agent "$1"; shift

LOG_DIR="$AGENT_LOG_DIR"
LATEST=$(ls -t "$LOG_DIR"/openclaw-*.log 2>/dev/null | head -1)
if [[ -z "$LATEST" ]]; then
  echo "No openclaw-*.log found in $LOG_DIR/"
  exit 1
fi

N=${1:-50}
if [[ "$N" == "follow" || "$N" == "-f" ]]; then
  echo "[$AGENT_NAME] Tailing $LATEST (Ctrl+C to stop)"
  if command -v jq >/dev/null 2>&1; then
    tail -f "$LATEST" | while read -r line; do echo "$line" | jq -r '.["msg"] // .["message"] // .["1"] // .["0"] // .' 2>/dev/null || echo "$line"; done
  else
    tail -f "$LATEST"
  fi
  exit 0
fi

echo "[$AGENT_NAME] Last $N entries from $LATEST"
echo "---"
if command -v jq >/dev/null 2>&1; then
  tail -n "$N" "$LATEST" | while read -r line; do echo "$line" | jq -r '.["msg"] // .["message"] // .["1"] // .["0"] // .' 2>/dev/null || echo "$line"; done
else
  tail -n "$N" "$LATEST"
fi
