#!/usr/bin/env bash
# PiFace log bridge — drive PiFace LCD from OpenClaw app log (Telegram run start/done).
# Runs on the Pi host; shows "THINKING..." on Telegram run start, "DONE" on run done.
# Use this so the display updates even when the agent does not call the piface-display skill.
#
# Usage: ./scripts/piface-log-bridge.sh [agent-name]
#   agent-name defaults to pibot. Requires jq. PiFace bridge must be running (port 18794).
#   Run in background or via systemd.

set -e
source "$(dirname "$0")/lib.sh"

AGENT="${1:-pibot}"
resolve_agent "$AGENT" 2>/dev/null || { echo "Usage: $0 [agent-name]" >&2; exit 1; }

PIFACE_URL="${PIFACE_DISPLAY_URL:-http://127.0.0.1:18794/display}"
LOG_DIR="$AGENT_LOG_DIR"

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

FLAG_FILE="${TMPDIR:-/tmp}/piface-log-bridge-telegram.$AGENT.flag"
DEBUG="${PIFACE_LOG_BRIDGE_DEBUG:-0}"
# After showing DONE, revert to system/idle message after this many seconds (default 60)
REVERT_SECS="${PIFACE_REVERT_SECS:-60}"
IDLE_L1="${PIFACE_IDLE_L1:-System}"
IDLE_L2="${PIFACE_IDLE_L2:-Ready}"

_display() {
  local l1="$1"
  local l2="${2:-}"
  [[ "$DEBUG" == "1" ]] && echo "PiFace log bridge: sending l1=$l1 l2=$l2" >&2
  curl -sf -m 2 -G \
    --data-urlencode "l1=$l1" \
    --data-urlencode "l2=$l2" \
    "$PIFACE_URL" >/dev/null 2>/dev/null || true
}

# Schedule revert to system info (IP + CPU + Mem) after REVERT_SECS. Runs the host
# system-display script so the display shows PiBot IP and utilization; fallback to IDLE_L1/L2 if script missing.
_schedule_revert() {
  local secs="$REVERT_SECS" script="${IRONCLAW_ROOT:-}/scripts/piface-system-display.sh"
  local url="$PIFACE_URL" l1="$IDLE_L1" l2="$IDLE_L2"
  ( sleep "$secs"
    if [[ -n "$script" && -x "$script" ]]; then
      "$script"
    else
      curl -sf -m 2 -G --data-urlencode "l1=$l1" --data-urlencode "l2=$l2" "$url" >/dev/null 2>/dev/null || true
    fi ) &
}

while true; do
  LATEST_LOG=$(ls -t "$LOG_DIR"/openclaw-*.log 2>/dev/null | head -1)
  [[ -z "$LATEST_LOG" || ! -f "$LATEST_LOG" ]] && { sleep 10; continue; }
  echo "PiFace log bridge: watching $LATEST_LOG (agent=$AGENT)" >&2
  timeout 300 tail -f "$LATEST_LOG" 2>/dev/null | while read -r line; do
    msg=$(echo "$line" | jq -r '.["1"] // empty' 2>/dev/null)
    [[ -z "$msg" ]] && continue
    if echo "$msg" | grep -qE '^embedded run start:'; then
      if echo "$msg" | grep -qE 'messageChannel=telegram'; then
        echo 1 > "$FLAG_FILE" 2>/dev/null || true
        _display "THINKING..." "Telegram"
      fi
    elif echo "$msg" | grep -qE '^embedded run done:'; then
      if [[ -f "$FLAG_FILE" ]]; then
        rm -f "$FLAG_FILE"
        if echo "$msg" | grep -qE 'aborted=true'; then
          _display "DONE" "Error"
        else
          _display "DONE" "OK"
        fi
        # Revert to system/idle message after REVERT_SECS so the display doesn't stay on DONE
        _schedule_revert
      fi
    fi
  done
  sleep 2
done
