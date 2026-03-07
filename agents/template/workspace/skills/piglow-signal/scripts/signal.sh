#!/usr/bin/env bash
# Send a PiGlow state to the host service. Safe to call from container; never fails the agent.
# Usage: signal.sh <state>
# States: idle, thinking, success, warning, error, attention, ready, off
# Service must run on Pi host (port 18793). No output on success; on failure logs to stderr and piglow-failures.log.
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_PIGLOW="$SKILL_DIR/../../piglow/signal_url"
if [[ -f "$SKILL_DIR/signal_url" ]]; then
  PIGLOW_URL=$(cat "$SKILL_DIR/signal_url")
elif [[ -f "$WORKSPACE_PIGLOW" ]]; then
  PIGLOW_URL=$(cat "$WORKSPACE_PIGLOW")
elif [[ -n "$PIGLOW_SIGNAL_URL" ]]; then
  PIGLOW_URL="$PIGLOW_SIGNAL_URL"
elif [[ -n "$PIGLOW_HOST" ]]; then
  PIGLOW_URL="http://${PIGLOW_HOST}:18793/signal"
else
  PIGLOW_URL="http://host.docker.internal:18793/signal"
fi
FAIL_LOG="/tmp/openclaw/piglow-failures.log"
STATE="${1:-idle}"
if curl -sf -m 3 -X POST "${PIGLOW_URL}?state=${STATE}" >/dev/null 2>/dev/null; then
    true
else
    ts=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
    msg="PIGLOW_UNREACHABLE container could not reach PiGlow bridge url=${PIGLOW_URL} at ${ts}"
    echo "piglow-signal: $msg" >&2
    [[ -w "$FAIL_LOG" || -w "$(dirname "$FAIL_LOG")" ]] 2>/dev/null && echo "$msg" >> "$FAIL_LOG"
fi
