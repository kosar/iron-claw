#!/usr/bin/env bash
# learning-log-bridge.sh
# Watches OpenClaw app logs and triggers internal quality feedback generation
# after each completed run ("embedded run done").
#
# Owner-only behavior:
# - Writes feedback to agents/{name}/logs/learning/
# - Optionally emails owner/configurator via existing send-email.sh
# - Never posts internal feedback to end-user channels
#
# Usage: ./scripts/learning-log-bridge.sh [agent-name]
#   agent-name defaults to ironclaw-bot

set -e
source "$(dirname "$0")/lib.sh"

AGENT="${1:-ironclaw-bot}"
resolve_agent "$AGENT" 2>/dev/null || { echo "Usage: $0 [agent-name]" >&2; exit 1; }

LOG_DIR="$AGENT_LOG_DIR"
BRIDGE_LOG="$AGENT_LOG_DIR/learning-bridge.log"
LEARNING_SCRIPT="$IRONCLAW_ROOT/scripts/learning-feedback.py"

if ! command -v jq >/dev/null 2>&1; then
  echo "learning-log-bridge: jq is required" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "learning-log-bridge: python3 is required" >&2
  exit 1
fi
if [[ ! -f "$LEARNING_SCRIPT" ]]; then
  echo "learning-log-bridge: missing script $LEARNING_SCRIPT" >&2
  exit 1
fi

timeout_cmd=()
if command -v timeout >/dev/null 2>&1; then
  timeout_cmd=(timeout 300)
elif command -v gtimeout >/dev/null 2>&1; then
  timeout_cmd=(gtimeout 300)
fi

kv() {
  local msg="$1"
  local key="$2"
  echo "$msg" | grep -oE "${key}=[^ ]+" | head -1 | cut -d= -f2
}

# Wait for first log file if bridge starts before gateway emits logs.
while true; do
  latest_log=$(ls -t "$LOG_DIR"/openclaw-*.log 2>/dev/null | head -1)
  [[ -n "$latest_log" && -f "$latest_log" ]] && break
  echo "learning-log-bridge: waiting for log file in $LOG_DIR..." >> "$BRIDGE_LOG"
  sleep 20
done

while true; do
  latest_log=$(ls -t "$LOG_DIR"/openclaw-*.log 2>/dev/null | head -1)
  [[ -z "$latest_log" || ! -f "$latest_log" ]] && { sleep 10; continue; }

  echo "learning-log-bridge: watching $latest_log (agent=$AGENT)" >> "$BRIDGE_LOG"

  if [[ ${#timeout_cmd[@]} -gt 0 ]]; then
    "${timeout_cmd[@]}" tail -f "$latest_log" 2>/dev/null | while read -r line; do
      msg=$(echo "$line" | jq -r '.["1"] // empty' 2>/dev/null)
      [[ -z "$msg" ]] && continue

      if echo "$msg" | grep -qE '^embedded run done:'; then
        run_id=$(kv "$msg" runId)
        session_id=$(kv "$msg" sessionId)
        duration_ms=$(kv "$msg" durationMs)
        aborted=$(kv "$msg" aborted)
        [[ -z "$duration_ms" ]] && duration_ms=0
        [[ -z "$aborted" ]] && aborted=false

        python3 "$LEARNING_SCRIPT" "$AGENT" \
          --log-file "$latest_log" \
          --run-id "$run_id" \
          --session-id "$session_id" \
          --duration-ms "$duration_ms" \
          --aborted "$aborted" \
          --done-msg "$msg" >> "$BRIDGE_LOG" 2>&1 || true
      fi
    done
  else
    # Fallback when timeout/gtimeout is unavailable (no periodic log rotation refresh).
    tail -f "$latest_log" 2>/dev/null | while read -r line; do
      msg=$(echo "$line" | jq -r '.["1"] // empty' 2>/dev/null)
      [[ -z "$msg" ]] && continue

      if echo "$msg" | grep -qE '^embedded run done:'; then
        run_id=$(kv "$msg" runId)
        session_id=$(kv "$msg" sessionId)
        duration_ms=$(kv "$msg" durationMs)
        aborted=$(kv "$msg" aborted)
        [[ -z "$duration_ms" ]] && duration_ms=0
        [[ -z "$aborted" ]] && aborted=false

        python3 "$LEARNING_SCRIPT" "$AGENT" \
          --log-file "$latest_log" \
          --run-id "$run_id" \
          --session-id "$session_id" \
          --duration-ms "$duration_ms" \
          --aborted "$aborted" \
          --done-msg "$msg" >> "$BRIDGE_LOG" 2>&1 || true
      fi
    done
  fi

  # timeout expired or tail exited; reopen latest log (handles daily rotation).
  sleep 2
done
