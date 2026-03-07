#!/usr/bin/env bash
# Sum token usage and cost from OpenClaw session JSONL files.
# Usage: ./scripts/usage-summary.sh <agent-name> [sessionId]
#   With no sessionId: process all sessions for the agent
#   With sessionId: process only that session's JSONL

set -e
source "$(dirname "$0")/lib.sh"
resolve_agent "$1"; shift

SESSIONS_DIR="$AGENT_SESSIONS"

if [[ -n "$1" ]]; then
  FILES=("$SESSIONS_DIR/$1.jsonl")
  [[ -f "${FILES[0]}" ]] || { echo "No such session: $1" >&2; exit 1; }
else
  FILES=("$SESSIONS_DIR"/*.jsonl)
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required. Install with: brew install jq" >&2
  exit 1
fi

input_total=0
output_total=0
cost_total=0
turns=0

for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  while IFS= read -r line; do
    role=$(echo "$line" | jq -r '.message.role // empty')
    [[ "$role" != "assistant" ]] && continue
    u=$(echo "$line" | jq -r '.message.usage // empty')
    [[ -z "$u" || "$u" == "null" ]] && continue
    i=$(echo "$u" | jq -r '.input // 0')
    o=$(echo "$u" | jq -r '.output // 0')
    c=$(echo "$u" | jq -r '.cost.total // 0')
    input_total=$(( input_total + i ))
    output_total=$(( output_total + o ))
    cost_total=$(echo "$cost_total + $c" | bc -l 2>/dev/null || echo "$cost_total")
    (( turns++ )) || true
  done < "$f"
done

echo "Agent: $AGENT_NAME"
echo "Session(s): ${FILES[*]}"
echo "Turns (assistant messages): $turns"
echo "Tokens  in:  $input_total"
echo "Tokens  out: $output_total"
echo "Total tokens: $(( input_total + output_total ))"
if [[ -n "$cost_total" && "$cost_total" != "0" ]]; then
  cost_fmt=$(printf "%.4f" "$cost_total" 2>/dev/null || echo "$cost_total")
  echo "Est. cost (USD): $cost_fmt"
fi
