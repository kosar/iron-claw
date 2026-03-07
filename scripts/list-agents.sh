#!/usr/bin/env bash
# list-agents.sh — Show all agents with their status, port, and resources.
# Usage: ./scripts/list-agents.sh

set -e
BASE="$(cd "$(dirname "$0")/.." && pwd)"

printf "%-20s %-7s %-6s %-6s %-24s %s\n" "AGENT" "PORT" "RAM" "CPUs" "CONTAINER" "STATUS"
printf "%-20s %-7s %-6s %-6s %-24s %s\n" "-----" "----" "---" "----" "---------" "------"

for dir in "$BASE"/agents/*/; do
  name=$(basename "$dir")
  [[ "$name" == "template" ]] && continue
  [[ -f "$dir/agent.conf" ]] || continue

  # Source agent.conf
  AGENT_PORT="" AGENT_MEM_LIMIT="" AGENT_CPUS="" AGENT_CONTAINER=""
  source "$dir/agent.conf"

  # Check container status
  status="stopped"
  if command -v docker >/dev/null 2>&1; then
    state=$(docker inspect --format='{{.State.Status}}' "$AGENT_CONTAINER" 2>/dev/null || true)
    if [[ -n "$state" ]]; then
      health=$(docker inspect --format='{{.State.Health.Status}}' "$AGENT_CONTAINER" 2>/dev/null || true)
      if [[ -n "$health" ]]; then
        status="${state} (${health})"
      else
        status="$state"
      fi
    fi
  fi

  printf "%-20s %-7s %-6s %-6s %-24s %s\n" \
    "$AGENT_NAME" "$AGENT_PORT" "$AGENT_MEM_LIMIT" "$AGENT_CPUS" "$AGENT_CONTAINER" "$status"
done
