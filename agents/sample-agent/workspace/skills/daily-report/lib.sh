#!/usr/bin/env bash
# lib.sh — Shared utilities for daily-report scripts

set -uo pipefail

# IronClaw root detection
IRONCLAW_ROOT="${IRONCLAW_ROOT:-$HOME/.openclaw}"
[[ -d "$IRONCLAW_ROOT" ]] || IRONCLAW_ROOT="/home/openclaw/.openclaw"

# Agent resolution
AGENT_NAME=""
AGENT_DIR=""
AGENT_LOG_DIR=""
AGENT_SESSIONS=""
AGENT_CONFIG=""
AGENT_WORKSPACE=""
AGENT_ENV=""
AGENT_PORT="${AGENT_PORT:-18789}"

list_agent_dirs() {
  local agents_dir="$IRONCLAW_ROOT/agents"
  if [[ -d "$agents_dir" ]]; then
    find "$agents_dir" -maxdepth 1 -type d ! -path "$agents_dir" -exec basename {} \;
  fi
}

resolve_agent() {
  local name="${1:-}"
  
  if [[ -z "$name" ]]; then
    # Try to find the first agent
    local first_agent
    first_agent=$(list_agent_dirs | head -1)
    if [[ -n "$first_agent" ]]; then
      name="$first_agent"
    else
      echo "Error: No agent specified and no agents found in $IRONCLAW_ROOT/agents/" >&2
      return 1
    fi
  fi
  
  AGENT_NAME="$name"
  AGENT_DIR="$IRONCLAW_ROOT/agents/$AGENT_NAME"
  AGENT_LOG_DIR="$AGENT_DIR/logs"
  AGENT_SESSIONS="$AGENT_DIR/sessions"
  AGENT_CONFIG="$AGENT_DIR/config"
  AGENT_WORKSPACE="$AGENT_DIR/workspace"
  AGENT_ENV="$AGENT_DIR/.env"
  
  # Create directories if they don't exist
  mkdir -p "$AGENT_LOG_DIR" "$AGENT_SESSIONS" "$AGENT_CONFIG" "$AGENT_WORKSPACE"
  
  # Detect port from env if available
  if [[ -f "$AGENT_ENV" ]]; then
    local port_from_env
    port_from_env=$(grep "PORT\|port" "$AGENT_ENV" 2>/dev/null | grep -oE '[0-9]+' | head -1)
    [[ -n "$port_from_env" ]] && AGENT_PORT="$port_from_env"
  fi
  
  export AGENT_NAME AGENT_DIR AGENT_LOG_DIR AGENT_SESSIONS AGENT_CONFIG AGENT_WORKSPACE AGENT_ENV AGENT_PORT IRONCLAW_ROOT
}
