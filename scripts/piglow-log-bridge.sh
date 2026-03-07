#!/usr/bin/env bash
# PiGlow log bridge — drive PiGlow from OpenClaw app log lifecycle (run start/done).
# Runs on the Pi host; triggers thinking on "embedded run start", success/error on "embedded run done".
# Use this for reliable activity indication even when the agent skips the piglow-signal skill.
#
# Usage: ./scripts/piglow-log-bridge.sh [agent-name]
#   agent-name defaults to pibot. Requires jq. PiGlow service must be running (port 18793).
#   Run in background or via systemd (e.g. same user unit as piglow-service, or a separate one).

set -e
source "$(dirname "$0")/lib.sh"

AGENT="${1:-pibot}"
resolve_agent "$AGENT" 2>/dev/null || { echo "Usage: $0 [agent-name]" >&2; exit 1; }

PIGLOW_URL="${PIGLOW_SIGNAL_URL:-http://127.0.0.1:18793/signal}"
LOG_DIR="$AGENT_LOG_DIR"

# When run under systemd at boot, log file may not exist yet; retry until it does
while true; do
  LATEST_LOG=$(ls -t "$LOG_DIR"/openclaw-*.log 2>/dev/null | head -1)
  [[ -n "$LATEST_LOG" && -f "$LATEST_LOG" ]] && break
  echo "Waiting for log file in $LOG_DIR..." >&2
  sleep 30
done

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

_signal() {
  local state="$1"
  curl -sf -m 2 -X POST "${PIGLOW_URL}?state=${state}" >/dev/null 2>/dev/null || true
}

# Follow latest log; re-check every 5 min so we pick up new day's file
while true; do
  LATEST_LOG=$(ls -t "$LOG_DIR"/openclaw-*.log 2>/dev/null | head -1)
  [[ -z "$LATEST_LOG" || ! -f "$LATEST_LOG" ]] && { sleep 10; continue; }
  echo "PiGlow log bridge: watching $LATEST_LOG (agent=$AGENT)" >&2
  timeout 300 tail -f "$LATEST_LOG" 2>/dev/null | while read -r line; do
    msg=$(echo "$line" | jq -r '.["msg"] // .["message"] // .["1"] // empty' 2>/dev/null) || msg=""
    [[ -z "$msg" ]] && continue
    if echo "$msg" | grep -qE '^embedded run start:'; then
      _signal thinking
    elif echo "$msg" | grep -qE '^embedded run done:'; then
      if echo "$msg" | grep -qE 'aborted=true'; then
        _signal error
      else
        _signal success
      fi
    fi
  done
  # timeout or tail exited; loop to re-open latest (e.g. after log rotation)
  sleep 2
done
