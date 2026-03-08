#!/usr/bin/env bash
# Prepare config-runtime from config/ then run docker compose up for a specific agent.
# This keeps config/ on the host untouched; the container mounts and writes to config-runtime only.
#
# Usage:
#   ./scripts/compose-up.sh <agent-name> [OPTIONS] [-- docker compose options...]
#   ./scripts/compose-up.sh ironclaw-bot --fresh   # reset config-runtime from config
#   ./scripts/compose-up.sh ironclaw-bot -d        # prepare then docker compose up -d
#
# Options:
#   --fresh   Remove config-runtime and copy config/ entirely (loses sessions, container-written models.json).
#   Otherwise: sync config/ → config-runtime/, excluding runtime-only paths so sessions persist.

set -e
source "$(dirname "$0")/lib.sh"
resolve_agent "$1"; shift

CONFIG_SRC="$AGENT_CONFIG"
CONFIG_RUNTIME="$AGENT_CONFIG_RUNTIME"

# Parse --fresh and remaining compose args
FRESH=false
COMPOSE_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fresh) FRESH=true; shift ;;
    *)      COMPOSE_ARGS+=("$1"); shift ;;
  esac
done

if [[ "$FRESH" == true ]]; then
  echo "[$AGENT_NAME] Removing config-runtime and doing a full copy from config/..."
  # Preserve device pairing state across fresh resets
  DEVICES_BAK=""
  if [[ -d "$CONFIG_RUNTIME/devices" ]]; then
    DEVICES_BAK=$(mktemp -d)
    cp -R "$CONFIG_RUNTIME/devices" "$DEVICES_BAK/devices"
  fi
  rm -rf "$CONFIG_RUNTIME"
  cp -R "$CONFIG_SRC" "$CONFIG_RUNTIME"
  if [[ -n "$DEVICES_BAK" ]]; then
    cp -R "$DEVICES_BAK/devices" "$CONFIG_RUNTIME/devices"
    rm -rf "$DEVICES_BAK"
    echo "  (preserved device pairing state)"
  fi
  echo "Done."
else
  if [[ ! -d "$CONFIG_RUNTIME" ]]; then
    echo "[$AGENT_NAME] First run: copying config/ to config-runtime/..."
    cp -R "$CONFIG_SRC" "$CONFIG_RUNTIME"
  else
    echo "[$AGENT_NAME] Syncing config/ → config-runtime/ (keeping sessions and container-written files)..."
    rsync -a \
      --exclude='agents/main/sessions' \
      --exclude='agents/main/agent/models.json' \
      --exclude='devices/' \
      --exclude='memory/main.sqlite' \
      --exclude='update-check.json' \
      --exclude='telegram/update-offset-*.json' \
      "$CONFIG_SRC"/ "$CONFIG_RUNTIME"/
  fi

  # Prepend host workspace/AGENTS.md into config-runtime/workspace/AGENTS.md
  if [[ -f "$AGENT_WORKSPACE/AGENTS.md" ]]; then
    mkdir -p "$CONFIG_RUNTIME/workspace"
    runtime_file="$CONFIG_RUNTIME/workspace/AGENTS.md"
    tmp=$(mktemp)
    if [[ -f "$runtime_file" ]] && grep -q "<!-- guidelines from host workspace/AGENTS.md -->" "$runtime_file" 2>/dev/null; then
      # Replace existing host block with fresh content (from first line until ---)
      { echo "<!-- guidelines from host workspace/AGENTS.md -->"; echo ""; cat "$AGENT_WORKSPACE/AGENTS.md"; echo ""; echo "---"; echo ""; sed -n '/^---$/,$ { /^---$/d; p }' "$runtime_file"; } > "$tmp"
    elif [[ -f "$runtime_file" ]]; then
      { echo "<!-- guidelines from host workspace/AGENTS.md -->"; echo ""; cat "$AGENT_WORKSPACE/AGENTS.md"; echo ""; echo "---"; echo ""; cat "$runtime_file"; } > "$tmp"
    else
      cp "$AGENT_WORKSPACE/AGENTS.md" "$tmp"
    fi
    mv "$tmp" "$runtime_file"
  fi

  # Sync host workspace skills
  if [[ -d "$AGENT_WORKSPACE/skills" ]]; then
    mkdir -p "$CONFIG_RUNTIME/workspace"
    rsync -a "$AGENT_WORKSPACE/skills/" "$CONFIG_RUNTIME/workspace/skills/"
  fi

  # Sync host workspace scripts (send-email.sh, etc.)
  if [[ -d "$AGENT_WORKSPACE/scripts" ]]; then
    mkdir -p "$CONFIG_RUNTIME/workspace/scripts"
    rsync -a "$AGENT_WORKSPACE/scripts/" "$CONFIG_RUNTIME/workspace/scripts/"
  fi

  echo "Done."
fi

# Inject port and enforce exec (no approval) in config-runtime/openclaw.json.
# Agents with EXEC_HOST=gateway in agent.conf run exec in the container — no Docker sandbox.
# Others get host=sandbox when available. HARDWARE_PROFILE=pi enables Pi-specific behavior below.
if command -v jq >/dev/null 2>&1; then
  use_gateway=false
  if [[ "${EXEC_HOST:-}" == "gateway" ]]; then
    use_gateway=true
  fi
  tmp_json=$(mktemp)
  jq --argjson port "$AGENT_PORT" --argjson use_gateway "$use_gateway" '
    .gateway.port = $port
    | if .tools.exec then
        .tools.exec.security = "full"
        | .tools.exec.ask = "off"
        | (if $use_gateway then
             .tools.exec.host = "gateway"
             | .agents.defaults.sandbox.mode = "off"
           else
             .tools.exec.host = "sandbox"
           end)
      else . end
  ' "$CONFIG_RUNTIME/openclaw.json" > "$tmp_json" && mv "$tmp_json" "$CONFIG_RUNTIME/openclaw.json"
fi

# Ensure logs directory exists (OpenClaw uses it as /tmp/openclaw and /tmp/openclaw-1000 in container)
mkdir -p "$AGENT_LOG_DIR"

# When compose-up is run with sudo, container (uid 1000) must be able to read config and write logs/workspace.
# Do not gate on HARDWARE_PROFILE=pi: sample-agent and any agent need this when run with sudo (e.g. Raspberry Pi).
if [[ $(id -u) -eq 0 ]]; then
  [[ -d "$CONFIG_RUNTIME" ]] && chown -R 1000:1000 "$CONFIG_RUNTIME"
  chown -R 1000:1000 "$AGENT_LOG_DIR"
  [[ -d "$AGENT_WORKSPACE" ]] && chown -R 1000:1000 "$AGENT_WORKSPACE"
fi

# Prune large session files to prevent unbounded growth from heartbeats
"$IRONCLAW_ROOT/scripts/prune-sessions.sh" "$AGENT_NAME"

# Heal broken sessions. --aggressive wipes sessions with .reset.* files.
# --startup also wipes sessions with thinkingSignature items (safe at startup
# since container is stopped; prevents 400 errors from OpenClaw's replay bug
# with gpt-5-mini reasoning items).
"$IRONCLAW_ROOT/scripts/heal-sessions.sh" "$AGENT_NAME" --aggressive --startup

# Generate docker-compose.yml from template via envsubst
# Detect host LAN subnet to pass to container for Ollama discovery
HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)
SCAN_SUBNET="${HOST_IP%.*}.0/24"
if [[ -z "$HOST_IP" || "$SCAN_SUBNET" == ".0/24" ]]; then
  echo "[$AGENT_NAME] ERROR: No host IP detected (hostname -I empty or unreachable). Cannot set SCAN_SUBNET. Start when network is up or run with network available." >&2
  exit 1
fi

# For Pi-style agents: dynamically detect Ollama on the network (discover-ollama.sh)
if [[ "${HARDWARE_PROFILE:-}" == "pi" ]]; then
  OLLAMA_TMP=$(mktemp)
  if bash "$IRONCLAW_ROOT/scripts/discover-ollama.sh" "$OLLAMA_TMP" 2>/dev/null && [[ -s "$OLLAMA_TMP" ]]; then
    OLLAMA_HOST=$(jq -r '[.hosts[]? | select(.host != "127.0.0.1" and .host != "host.docker.internal") | .host] | .[0] // empty' "$OLLAMA_TMP" 2>/dev/null)
    [[ -z "$OLLAMA_HOST" ]] && OLLAMA_HOST=$(jq -r '.hosts[0].host // empty' "$OLLAMA_TMP" 2>/dev/null)
    [[ -n "$OLLAMA_HOST" ]] && echo "[$AGENT_NAME] Ollama detected at $OLLAMA_HOST" >&2
  fi
  rm -f "$OLLAMA_TMP"
fi
export OLLAMA_HOST="${OLLAMA_HOST:-host.docker.internal}"
# Pi-style agents: inject host IP for PiGlow so container can reach host service (host.docker.internal can fail on some Pi/Docker)
if [[ "${HARDWARE_PROFILE:-}" == "pi" ]] && [[ -n "$HOST_IP" ]]; then
  export PIGLOW_HOST="$HOST_IP"
  # Write PiGlow URL into host workspace (container mounts ./workspace at .openclaw/workspace, so the skill sees it)
  PIGLOW_URL="http://${HOST_IP}:18793/signal"
  for dir in "$AGENT_WORKSPACE/skills/piglow-signal" "$AGENT_WORKSPACE/piglow"; do
    if [[ -d "$dir" ]]; then
      echo "$PIGLOW_URL" > "$dir/signal_url"
    fi
  done
else
  export PIGLOW_HOST="${PIGLOW_HOST:-host.docker.internal}"
fi
export AGENT_NAME AGENT_PORT AGENT_CONTAINER AGENT_MEM_LIMIT AGENT_CPUS AGENT_SHM_SIZE SCAN_SUBNET
envsubst < "$IRONCLAW_ROOT/scripts/docker-compose.yml.tmpl" > "$AGENT_DIR/docker-compose.yml"

COMPOSE_FILES=(-f "$AGENT_DIR/docker-compose.yml")
OVERRIDE_FILE="$AGENT_DIR/docker-compose.override.yml"
USE_OVERRIDE=false

# Pi + LIRC override: wait for IR device to exist (and be readable) so container gets it on start.
# Only include the override if the LIRC device exists; otherwise Docker fails with "no such file or directory".
# After reboot, /dev/lirc0 may appear after udev; we wait up to 30s then include override only when device is present.
if [[ -f "$OVERRIDE_FILE" ]]; then
  if [[ "${HARDWARE_PROFILE:-}" != "pi" ]] || ! grep -q "lirc" "$OVERRIDE_FILE" 2>/dev/null; then
    USE_OVERRIDE=true
  else
    LIRC_DEV=$(grep -oE '/dev/lirc[0-9]+' "$OVERRIDE_FILE" 2>/dev/null | head -1)
    if [[ -n "$LIRC_DEV" ]]; then
      LIRC_WAIT=0
      while [[ $LIRC_WAIT -lt 30 ]]; do
        if [[ -r "$LIRC_DEV" ]] 2>/dev/null; then
          echo "[$AGENT_NAME] IR device $LIRC_DEV ready." >&2
          USE_OVERRIDE=true
          break
        fi
        [[ $LIRC_WAIT -eq 0 ]] && echo "[$AGENT_NAME] Waiting for $LIRC_DEV (up to 30s)..." >&2
        sleep 2
        LIRC_WAIT=$((LIRC_WAIT + 2))
      done
      if ! [[ -r "$LIRC_DEV" ]] 2>/dev/null; then
        echo "[$AGENT_NAME] WARNING: $LIRC_DEV not found or not readable. Skipping IR override so container can start; IR blaster will be unavailable. Install udev rule (see docs/IR-DONGLE.md) and ensure dongle is bound to mceusb." >&2
      fi
    else
      USE_OVERRIDE=true
    fi
  fi
fi
[[ "$USE_OVERRIDE" == true ]] && COMPOSE_FILES+=(-f "$OVERRIDE_FILE")

echo "[$AGENT_NAME] Starting compose (container: $AGENT_CONTAINER, port: $AGENT_PORT)..."
docker compose -p "$AGENT_NAME" "${COMPOSE_FILES[@]}" up "${COMPOSE_ARGS[@]}"

# Start/refresh the internal learning bridge when running detached.
# This creates owner-only quality feedback after each completed run.
if [[ " ${COMPOSE_ARGS[*]} " == *" -d "* ]]; then
  if [[ "${IRONCLAW_DISABLE_LEARNING_BRIDGE:-0}" != "1" ]]; then
    LEARNING_BRIDGE="$IRONCLAW_ROOT/scripts/learning-log-bridge.sh"
    LEARNING_PID_FILE="$AGENT_LOG_DIR/learning-bridge.pid"
    LEARNING_LOG_FILE="$AGENT_LOG_DIR/learning-bridge.log"

    if [[ -f "$LEARNING_PID_FILE" ]]; then
      old_pid=$(cat "$LEARNING_PID_FILE" 2>/dev/null || true)
      if [[ -n "$old_pid" ]] && ps -p "$old_pid" >/dev/null 2>&1; then
        old_cmd=$(ps -o command= -p "$old_pid" 2>/dev/null || true)
        if echo "$old_cmd" | grep -qE "learning-log-bridge\.sh[[:space:]]+$AGENT_NAME"; then
          kill "$old_pid" >/dev/null 2>&1 || true
          sleep 1
        fi
      fi
      rm -f "$LEARNING_PID_FILE"
    fi

    if [[ -f "$LEARNING_BRIDGE" ]]; then
      nohup bash "$LEARNING_BRIDGE" "$AGENT_NAME" >> "$LEARNING_LOG_FILE" 2>&1 &
      bridge_pid=$!
      echo "$bridge_pid" > "$LEARNING_PID_FILE"
      echo "[$AGENT_NAME] Learning bridge started (pid $bridge_pid)."
    else
      echo "[$AGENT_NAME] Learning bridge script missing at $LEARNING_BRIDGE; skipping." >&2
    fi
  else
    echo "[$AGENT_NAME] Learning bridge disabled (IRONCLAW_DISABLE_LEARNING_BRIDGE=1)."
  fi
fi

# Pi-style agents (Pi host): trigger PiGlow "ready" light show so users see bot is up.
if [[ "${HARDWARE_PROFILE:-}" == "pi" ]] && [[ " ${COMPOSE_ARGS[*]} " == *" -d "* ]]; then
  sleep 4
  curl -sf -m 5 "http://127.0.0.1:18793/signal?state=ready" >/dev/null 2>&1 || true
fi
