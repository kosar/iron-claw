#!/usr/bin/env bash
# check-nexus-logs.sh — View Shopify Nexus search logs for a specific agent
#
# Usage:
#   ./scripts/check-nexus-logs.sh <agent-name>              # last 20 entries
#   ./scripts/check-nexus-logs.sh <agent-name> 50           # last 50 entries
#   ./scripts/check-nexus-logs.sh <agent-name> follow       # tail -f (live)
#   ./scripts/check-nexus-logs.sh <agent-name> errors       # only errors and failures
#   ./scripts/check-nexus-logs.sh <agent-name> domain X     # only entries for domain X
#   ./scripts/check-nexus-logs.sh <agent-name> summary      # search_complete entries only
#   ./scripts/check-nexus-logs.sh <agent-name> corrections  # domain_correction entries only
#   ./scripts/check-nexus-logs.sh <agent-name> empty        # searches with 0 products

source "$(dirname "$0")/lib.sh"
resolve_agent "$1"; shift

LOG_FILE="$AGENT_LOG_DIR/nexus-search.log"

if [ ! -f "$LOG_FILE" ]; then
  echo "No nexus search log found at $LOG_FILE"
  echo "The log is created on the first search. Try searching a Shopify store first."
  exit 0
fi

MODE="${1:-20}"

case "$MODE" in
  follow)
    echo "Following $LOG_FILE (Ctrl+C to stop)..."
    tail -f "$LOG_FILE" | while read -r line; do
      echo "$line" | jq -c '.' 2>/dev/null || echo "$line"
    done
    ;;
  errors)
    grep -E '"status":"(error|rejected|timeout|404)"' "$LOG_FILE" | jq -c '.' 2>/dev/null || cat
    ;;
  domain)
    DOMAIN="${2:?Usage: $0 <agent-name> domain <domain>}"
    grep "\"domain\":\"${DOMAIN}\"" "$LOG_FILE" | jq -c '.' 2>/dev/null || cat
    ;;
  summary)
    grep '"event":"search_complete"' "$LOG_FILE" | jq -c '.' 2>/dev/null || cat
    ;;
  corrections)
    grep '"event":"domain_correction"' "$LOG_FILE" | jq -c '.' 2>/dev/null || cat
    ;;
  empty)
    grep '"products":0\|"products":"0"\|"status":"empty"' "$LOG_FILE" | jq -c '.' 2>/dev/null || cat
    ;;
  *)
    # Treat as number of lines
    tail -n "$MODE" "$LOG_FILE" | jq -c '.' 2>/dev/null || tail -n "$MODE" "$LOG_FILE"
    ;;
esac
