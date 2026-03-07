#!/usr/bin/env bash
# Quick failure check: runs the full log analyzer with default scope and optional reply scan.
# For powerful server-side analysis (categories, summary, --days, --category) use analyze-logs.sh directly.
#
# Usage: ./scripts/check-failures.sh <agent-name> [N]     — last N lines (default 500); "all" = full today log
#        ./scripts/check-failures.sh <agent-name> --replies  — also scan assistant replies for "can't / missing API key" etc.

set -e
SCRIPT_DIR="$(dirname "$0")"
AGENT_NAME="$1"
[[ -z "$AGENT_NAME" ]] && { echo "Usage: $0 <agent-name> [N|--replies|all]" >&2; exit 1; }
shift

if [[ "$1" == "--replies" ]]; then
  exec "$SCRIPT_DIR/analyze-logs.sh" "$AGENT_NAME" --last 500 --replies
fi

N=${1:-500}
if [[ "$N" == "all" ]]; then
  exec "$SCRIPT_DIR/analyze-logs.sh" "$AGENT_NAME" --all
fi
exec "$SCRIPT_DIR/analyze-logs.sh" "$AGENT_NAME" --last "$N"
