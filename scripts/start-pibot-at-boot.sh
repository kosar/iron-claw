#!/usr/bin/env bash
# start-pibot-at-boot.sh — Wait for host IP, then run compose-up.sh pibot -d.
# Used by systemd at boot so pibot starts only after the network (e.g. Wi‑Fi) has an IP.
#
# Usage: run by ironclaw-pibot.service (absolute path). No args.

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IRONCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

WAIT_TIMEOUT=90
WAIT_INTERVAL=5
ELAPSED=0

while [[ $ELAPSED -lt $WAIT_TIMEOUT ]]; do
  IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  if [[ -n "$IP" ]]; then
    break
  fi
  sleep "$WAIT_INTERVAL"
  ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

if [[ -z "$IP" ]]; then
  echo "start-pibot-at-boot: No host IP after ${WAIT_TIMEOUT}s (hostname -I empty). Aborting." >&2
  exit 1
fi

"$SCRIPT_DIR/compose-up.sh" pibot -d

# PiGlow: show "ready" (idle = dim white) so the user sees the bot is up
curl -sf -m 2 -X POST "${PIGLOW_SIGNAL_URL:-http://127.0.0.1:18793/signal}?state=idle" >/dev/null 2>/dev/null || true

# PiFace: show host system message (IP + memory) so the display isn't empty until heartbeat
"$SCRIPT_DIR/piface-system-display.sh" 2>/dev/null || true
