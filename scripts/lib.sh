#!/usr/bin/env bash
# lib.sh — Shared agent resolution helper for ironclaw-core.
# Source this from any script that operates on a specific agent.
#
# Usage (in other scripts):
#   source "$(dirname "$0")/lib.sh"
#   resolve_agent "$1"; shift
#
# After resolve_agent, the following are exported:
#   AGENT_DIR           — /path/to/agents/{name}
#   AGENT_NAME          — from agent.conf
#   AGENT_PORT          — from agent.conf
#   AGENT_CONTAINER     — from agent.conf
#   AGENT_MEM_LIMIT     — from agent.conf
#   AGENT_CPUS          — from agent.conf
#   AGENT_SHM_SIZE      — from agent.conf
#   EXEC_HOST           — optional; "gateway" = exec in container, no sandbox (for pibot-type agents)
#   AGENT_LOG_DIR       — $AGENT_DIR/logs
#   AGENT_CONFIG        — $AGENT_DIR/config
#   AGENT_CONFIG_RUNTIME — $AGENT_DIR/config-runtime
#   AGENT_WORKSPACE     — $AGENT_DIR/workspace
#   AGENT_SESSIONS      — $AGENT_DIR/config-runtime/agents/main/sessions
#   AGENT_ENV           — $AGENT_DIR/.env
#   IRONCLAW_ROOT       — repo root

resolve_agent() {
  local name="${1:?Usage: $0 <agent-name> [...]}"
  local base
  base="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)"

  local dir="$base/agents/$name"
  [[ -d "$dir" ]] || { echo "Error: Agent '$name' not found in agents/" >&2; exit 1; }
  [[ -f "$dir/agent.conf" ]] || { echo "Error: Agent '$name' missing agent.conf" >&2; exit 1; }

  # Source agent.conf to get AGENT_NAME, AGENT_PORT, etc.
  source "$dir/agent.conf"

  export AGENT_DIR="$dir"
  export AGENT_LOG_DIR="$dir/logs"
  export AGENT_CONFIG="$dir/config"
  export AGENT_CONFIG_RUNTIME="$dir/config-runtime"
  export AGENT_WORKSPACE="$dir/workspace"
  export AGENT_SESSIONS="$dir/config-runtime/agents/main/sessions"
  export AGENT_ENV="$dir/.env"
  export IRONCLAW_ROOT="$base"
}

# List all agent directories (excluding template)
list_agent_dirs() {
  local base
  base="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)"
  for d in "$base"/agents/*/; do
    local name=$(basename "$d")
    [[ "$name" == "template" ]] && continue
    [[ -f "$d/agent.conf" ]] && echo "$name"
  done
}
