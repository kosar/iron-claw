#!/usr/bin/env bash
# compose-up-all.sh — Start all agents (or named subset).
#
# Usage:
#   ./scripts/compose-up-all.sh              # start all agents
#   ./scripts/compose-up-all.sh bot1 bot2    # start only bot1 and bot2
#
# All agents are started with -d (detached). Skips "template".

set -e
BASE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(dirname "$0")"

# Collect agent names
if [[ $# -gt 0 ]]; then
  AGENTS=("$@")
else
  AGENTS=()
  for dir in "$BASE"/agents/*/; do
    name=$(basename "$dir")
    [[ "$name" == "template" ]] && continue
    [[ -f "$dir/agent.conf" ]] || continue
    AGENTS+=("$name")
  done
fi

if [[ ${#AGENTS[@]} -eq 0 ]]; then
  echo "No agents found to start."
  exit 0
fi

echo "Starting ${#AGENTS[@]} agent(s): ${AGENTS[*]}"
echo ""

FAILED=0
for name in "${AGENTS[@]}"; do
  echo "── Starting $name ──"
  if "$SCRIPT_DIR/compose-up.sh" "$name" -d; then
    echo "[$name] Started successfully."
  else
    echo "[$name] FAILED to start."
    FAILED=$((FAILED + 1))
  fi
  echo ""
done

if [[ $FAILED -gt 0 ]]; then
  echo "Warning: $FAILED agent(s) failed to start."
  exit 1
fi

echo "All agents started. Run ./scripts/list-agents.sh to check status."
