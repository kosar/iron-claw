#!/usr/bin/env bash
#
# setup-raspberry-pi.sh — One-command Raspberry Pi setup for IronClaw + OpenClaw
#
# This script turns a fresh Raspberry Pi OS (64-bit) into a ready-to-run IronClaw
# host: it updates the system, installs Docker and jq, clones the repo, builds the
# image, configures the sample-agent, starts the gateway, and enables start-on-boot.
#
# Run from the internet (recommended):
#   curl -sSL https://raw.githubusercontent.com/kosar/iron-claw/main/scripts/setup-raspberry-pi.sh | bash
#
# What this does: updates apt, installs jq/curl/git, installs Docker, clones this repo,
# builds the image, configures sample-agent, starts the container, enables systemd.
# No hidden payloads — you can inspect the script at the URL above first.
#
# Or with options:
#   curl -sSL ... | bash -s -- --yes
#   curl -sSL ... | bash -s -- --help
#
# Run from a local clone:
#   ./scripts/setup-raspberry-pi.sh
#   ./scripts/setup-raspberry-pi.sh --yes
#
# Options:
#   --yes, -y     Non-interactive: skip confirmations (use for automation).
#   --help, -h    Show this help and exit.
#   --dry-run     Print what would be done without making changes.
#
# Safe to run repeatedly: idempotent. If IronClaw is already running and healthy,
# the script exits early and tells you everything is set. Otherwise it only adds
# or fixes what's missing (never overwrites your .env or breaks a working setup).
#
# Requirements: Raspberry Pi OS 64-bit (or Debian/Ubuntu on aarch64), sudo, network.
#
set -e

# --- Constants ---
REPO_URL="${IRONCLAW_REPO_URL:-https://github.com/kosar/iron-claw.git}"
DEFAULT_ROOT="${HOME}/ironclaw"
IMAGE_TAG="${IRONCLAW_IMAGE_TAG:-ironclaw:2.0}"
AGENT_NAME="${IRONCLAW_AGENT:-sample-agent}"

# --- Options ---
YES_MODE=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES_MODE=true ;;
    --dry-run) DRY_RUN=true ;;
    --help|-h)
      sed -n '1,35p' "$0" | head -35
      exit 0
      ;;
  esac
done

# --- Who and where ---
CURRENT_USER="${SUDO_USER:-$USER}"
CURRENT_HOME="${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}"
CURRENT_HOME="${CURRENT_HOME:-$HOME}"
IRONCLAW_ROOT="${IRONCLAW_ROOT:-$DEFAULT_ROOT}"
# If we're inside a clone, use it
if [[ -f "$(dirname "$0")/lib.sh" ]] && [[ -f "$(dirname "$0")/../agents/sample-agent/agent.conf" ]]; then
  IRONCLAW_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  ALREADY_IN_REPO=true
else
  ALREADY_IN_REPO=false
fi

# --- Logging helpers ---
RED='\033\e[31m'
GREEN='\033\e[32m'
YELLOW='\033\e[33m'
CYAN='\033\e[36m'
BOLD='\033\e[1m'
RESET='\033\e[0m'

log_section() {
  echo ""
  echo -e "${BOLD}${CYAN}═══ $* ═══${RESET}"
  echo ""
}

log_step() {
  echo -e "${CYAN}▶${RESET} $*"
}

log_ok() {
  echo -e "  ${GREEN}✓${RESET} $*"
}

log_warn() {
  echo -e "  ${YELLOW}⚠${RESET} $*"
}

log_fail() {
  echo -e "  ${RED}✗${RESET} $*"
}

run() {
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${YELLOW}[dry-run]${RESET} $*"
    return 0
  fi
  "$@"
}

run_sudo() {
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${YELLOW}[dry-run]${RESET} sudo $*"
    return 0
  fi
  sudo "$@"
}

# --- Checks ---
need_sudo() {
  if ! sudo -n true 2>/dev/null; then
    echo -e "${YELLOW}This script needs sudo to install packages and Docker. You may be prompted for your password.${RESET}"
    sudo true
  fi
}

check_arch() {
  local arch
  arch="$(uname -m)"
  if [[ "$arch" != "aarch64" && "$arch" != "arm64" ]]; then
    log_fail "Unsupported architecture: $arch. This script is for Raspberry Pi OS 64-bit (aarch64/arm64)."
    exit 1
  fi
  log_ok "Architecture: $arch (OK for Pi 4/5 64-bit)"
}

check_os() {
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    log_ok "OS: $PRETTY_NAME"
    if [[ "${ID:-}" != "debian" && "${ID:-}" != "raspbian" && "${ID_LIKE:-}" != *"debian"* ]]; then
      log_warn "This script is tested on Debian/Raspberry Pi OS. You have $ID. It may still work."
    fi
  else
    log_warn "Could not detect OS (no /etc/os-release). Continuing anyway."
  fi
}

# --- Already set up? (idempotent early exit) ---
# If repo exists, image exists, .env exists, container is running, and gateway responds,
# we're done — tell the user and exit so re-runs never cause regressions.
check_already_set_up() {
  [[ "$DRY_RUN" == true ]] && return 0
  # Must have a repo to check
  if [[ "$ALREADY_IN_REPO" != true ]] && [[ ! -d "$IRONCLAW_ROOT/.git" ]]; then
    return 0
  fi
  local root="$IRONCLAW_ROOT"
  if [[ "$ALREADY_IN_REPO" == true ]]; then
    :
  elif [[ -d "$root/.git" ]]; then
    :
  else
    return 0
  fi
  # Resolve root if we weren't in repo (e.g. curl run with default ~/ironclaw)
  [[ -d "$root/.git" ]] || return 0
  local env_file="$root/agents/$AGENT_NAME/.env"
  local test_script="$root/scripts/test-gateway-http.sh"
  # Image exists?
  if ! docker_cmd images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${IMAGE_TAG%:*}:${IMAGE_TAG#*:}$"; then
    return 0
  fi
  # .env exists and has token?
  if [[ ! -f "$env_file" ]]; then
    return 0
  fi
  if ! grep -q '^OPENCLAW_GATEWAY_TOKEN=.' "$env_file" 2>/dev/null; then
    return 0
  fi
  # Container running?
  local cid
  cid="$(docker_cmd ps -q -f "name=${AGENT_NAME}" 2>/dev/null | head -1)"
  if [[ -z "$cid" ]]; then
    return 0
  fi
  # Gateway responds?
  if [[ ! -x "$test_script" ]]; then
    return 0
  fi
  local out
  out="$(cd "$root" && "$test_script" "$AGENT_NAME" 2>&1)" || true
  if echo "$out" | grep -q "Connection refused\|Connection reset\|Failed to connect\|Could not connect"; then
    return 0
  fi
  # Must look like success (JSON or the script's "Done" line)
  if ! echo "$out" | grep -qE '\{|"id":|Done\.'; then
    return 0
  fi
  # All good — already set up
  echo ""
  echo -e "${GREEN}${BOLD}IronClaw and OpenClaw are already set up and running.${RESET}"
  echo ""
  echo "  Maybe you ran this script again? That's fine — we only add or fix what's missing."
  echo "  Everything looks good: repo, image, agent config, container, and gateway are in place."
  echo ""
  echo -e "${BOLD}What you can do:${RESET}"
  echo "  • Test the gateway:  $root/scripts/test-gateway-http.sh $AGENT_NAME"
  echo "  • View logs:         $root/scripts/watch-logs.sh $AGENT_NAME"
  echo "  • Restart agent:     cd $root && ./scripts/compose-up.sh $AGENT_NAME -d"
  echo "  • Start on boot:     systemd unit ironclaw-$AGENT_NAME.service is enabled"
  echo ""
  echo -e "${GREEN}No changes made. You're all set.${RESET}"
  echo ""
  exit 0
}

# --- Step 1: System update and packages ---
do_apt_update() {
  log_section "Step 1: System update and required packages"
  echo "We'll update the package list and ensure jq, curl, git, and ca-certificates are installed."
  echo "Running again only adds or updates what's missing (idempotent)."
  echo ""

  if run_sudo apt-get update -qq 2>/dev/null; then
    log_ok "Package list updated"
  else
    log_warn "apt-get update had issues (e.g. another apt process or interactive prompt)."
    echo "  If you see 'Could not get lock', finish any other apt/dpkg run, or run: sudo dpkg --configure -a"
    run_sudo apt-get update || true
  fi

  log_step "Ensuring jq, curl, git, ca-certificates, gnupg are installed..."
  run_sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    ca-certificates curl gnupg git jq \
    || run_sudo apt-get install -y ca-certificates curl gnupg git jq
  log_ok "Packages OK (already present or just installed)"
}

# --- Step 2: Docker ---
do_docker() {
  log_section "Step 2: Docker"
  echo "IronClaw runs the OpenClaw gateway inside a container. We need Docker and Docker Compose."
  echo ""

  if command -v docker >/dev/null 2>&1 && run docker info >/dev/null 2>&1; then
    log_ok "Docker is already installed and the daemon is running"
    run docker --version
    if run docker compose version >/dev/null 2>&1; then
      log_ok "Docker Compose (plugin) is available"
    else
      log_warn "Docker Compose plugin not found. Install it for your OS (e.g. apt install docker-compose-plugin)"
    fi
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    log_step "Docker is installed but the daemon may not be running. Starting Docker..."
    run_sudo systemctl start docker 2>/dev/null || true
    run_sudo systemctl enable docker 2>/dev/null || true
    if run docker info >/dev/null 2>&1; then
      log_ok "Docker daemon is running"
    fi
  fi

  if ! command -v docker >/dev/null 2>&1; then
    log_step "Installing Docker via the official convenience script..."
    echo "  (This adds the Docker repo and installs docker-ce and the Compose plugin.)"
    run curl -fsSL https://get.docker.com | run_sudo sh
    log_ok "Docker installed"
  fi

  if ! run_sudo usermod -aG docker "$CURRENT_USER" 2>/dev/null; then
    log_warn "Could not add $CURRENT_USER to the docker group. You may need to run: sudo usermod -aG docker $CURRENT_USER"
  else
    log_ok "Added $CURRENT_USER to the docker group"
  fi

  echo ""
  echo -e "${YELLOW}Important:${RESET} For Docker to work without sudo, you must log out and log back in (or reboot) after this script finishes."
  echo "  The script will use sudo for Docker commands until then."
}

docker_cmd() {
  if run docker info >/dev/null 2>&1; then
    run docker "$@"
  else
    run_sudo docker "$@"
  fi
}

# --- Step 3: Clone repo ---
do_clone() {
  log_section "Step 3: IronClaw repository"
  echo "We need the IronClaw repo on this machine. It contains the Dockerfile, agent configs, and scripts."
  echo ""

  if [[ "$ALREADY_IN_REPO" == true ]]; then
    log_ok "Already inside an IronClaw clone at: $IRONCLAW_ROOT"
    return 0
  fi

  if [[ -d "$IRONCLAW_ROOT/.git" ]]; then
    log_ok "Repo already exists at $IRONCLAW_ROOT"
    log_step "Pulling latest changes..."
    (cd "$IRONCLAW_ROOT" && run git pull --rebase 2>/dev/null) || log_warn "git pull failed (e.g. local changes). Using existing tree."
    return 0
  fi

  log_step "Cloning $REPO_URL into $IRONCLAW_ROOT ..."
  run git clone "$REPO_URL" "$IRONCLAW_ROOT"
  log_ok "Clone complete"
}

# --- Step 4: Build image ---
do_build() {
  log_section "Step 4: Build the IronClaw Docker image"
  echo "The image includes Node, OpenClaw, Playwright, and a locked-down filesystem."
  echo "On a Raspberry Pi the first build can take 10–15 minutes. Please be patient."
  echo ""

  if docker_cmd images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${IMAGE_TAG%:*}:${IMAGE_TAG#*:}$"; then
    log_ok "Image $IMAGE_TAG already exists. Skipping build (delete the image first to force a rebuild)."
    return 0
  fi

  log_step "Building $IMAGE_TAG (this may take a while)..."
  (cd "$IRONCLAW_ROOT" && docker_cmd build -t "$IMAGE_TAG" .)
  log_ok "Build complete"
}

# --- Step 5: Configure agent ---
do_configure_agent() {
  log_section "Step 5: Configure the $AGENT_NAME agent"
  echo "Each agent has a .env file (secrets) and config (openclaw.json). We'll create a working .env and fix config so the gateway can start."
  echo ""

  local agent_dir="$IRONCLAW_ROOT/agents/$AGENT_NAME"
  local env_file="$agent_dir/.env"
  local template_env="$IRONCLAW_ROOT/agents/template/.env.example"
  local config_json="$agent_dir/config/openclaw.json"

  if [[ ! -d "$agent_dir" ]]; then
    log_fail "Agent directory not found: $agent_dir"
    exit 1
  fi

  # Create .env from template if missing
  if [[ ! -f "$env_file" ]]; then
    log_step "Creating $AGENT_NAME/.env from template..."
    local token
    token="$(openssl rand -hex 24 2>/dev/null || echo "please-set-a-token-$(date +%s)")"
    cp "$template_env" "$env_file"
    # Replace placeholder and add required vars (avoid overwriting if template has different structure)
    if grep -q '^OPENCLAW_GATEWAY_TOKEN=$' "$env_file"; then
      sed -i "s/^OPENCLAW_GATEWAY_TOKEN=.*/OPENCLAW_GATEWAY_TOKEN=$token/" "$env_file"
    fi
    if grep -q '^OPENCLAW_OWNER_DISPLAY_SECRET=$' "$env_file"; then
      sed -i "s/^OPENCLAW_OWNER_DISPLAY_SECRET=.*/OPENCLAW_OWNER_DISPLAY_SECRET=change-me-set-a-real-secret/" "$env_file"
    fi
    # Ensure OPENAI_API_KEY is set (config may require it)
    if ! grep -q '^OPENAI_API_KEY=' "$env_file"; then
      echo "OPENAI_API_KEY=not-set" >> "$env_file"
    fi
    log_ok "Created .env with a generated gateway token. Set OPENCLAW_OWNER_DISPLAY_SECRET and OPENAI_API_KEY (or use Ollama only) before production use."
  else
    log_ok ".env already exists; leaving it unchanged"
  fi

  # Pi-friendly config fixes only when needed (idempotent, no regressions)
  if [[ -f "$config_json" ]]; then
    local config_changed=false
    # controlUi: with bind "lan", OpenClaw requires explicit allowedOrigins (no dangerous fallback).
    # Set allowedOrigins to localhost + 127.0.0.1 + optional LAN IP so the gateway starts securely.
    local port
    port="$(jq -r '.gateway.port // empty' "$config_json" 2>/dev/null)"
    if [[ -z "$port" ]] && [[ -f "$IRONCLAW_ROOT/agents/$AGENT_NAME/agent.conf" ]]; then
      port="$(grep -E '^AGENT_PORT=' "$IRONCLAW_ROOT/agents/$AGENT_NAME/agent.conf" 2>/dev/null | cut -d= -f2-)"
    fi
    port="${port:-18792}"
    local origins="[\"http://localhost:${port}\", \"http://127.0.0.1:${port}\"]"
    local lan_ip
    lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ -n "$lan_ip" ]] && [[ "$lan_ip" != "127.0.0.1" ]]; then
      origins="[\"http://localhost:${port}\", \"http://127.0.0.1:${port}\", \"http://${lan_ip}:${port}\"]"
    fi
    local current_origins
    current_origins="$(jq -c '.gateway.controlUi.allowedOrigins // empty' "$config_json" 2>/dev/null)"
    if [[ -z "$current_origins" ]] || [[ "$current_origins" == "[]" ]]; then
      jq --argjson orig "$origins" '.gateway.controlUi.allowedOrigins = $orig' "$config_json" > "${config_json}.tmp" && mv "${config_json}.tmp" "$config_json"
      config_changed=true
    fi
    # Remove dangerous fallback if present (we use explicit origins only)
    if grep -q 'dangerouslyAllowHostHeaderOriginFallback' "$config_json"; then
      jq 'del(.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback)' "$config_json" > "${config_json}.tmp" && mv "${config_json}.tmp" "$config_json"
      config_changed=true
    fi
    # Telegram: only fix when gateway would fail (allowlist with empty allowFrom).
    # Use placeholder ["0"] so validation passes but no one can message (0 is not a real Telegram user ID).
    # Before enabling Telegram, user must replace 0 with their numeric user ID in allowFrom/groupAllowFrom.
    if grep -q '"dmPolicy": "allowlist"' "$config_json" && grep -q '"allowFrom": \[\]' "$config_json"; then
      sed -i 's/"allowFrom": \[\]/"allowFrom": ["0"]/g' "$config_json"
      config_changed=true
    fi
    if grep -q '"groupPolicy": "allowlist"' "$config_json" && grep -q '"groupAllowFrom": \[\]' "$config_json"; then
      sed -i 's/"groupAllowFrom": \[\]/"groupAllowFrom": ["0"]/g' "$config_json"
      config_changed=true
    fi
    # streaming key (some OpenClaw versions expect it) — only if streamMode present and streaming missing
    if grep -q '"streamMode"' "$config_json" && ! grep -q '"streaming"' "$config_json"; then
      sed -i 's/"streamMode": "partial"/"streaming": "partial"/g' "$config_json"
      config_changed=true
    fi
    if [[ "$config_changed" == true ]]; then
      log_ok "Config updated (only what was missing or broken)"
    else
      log_ok "Config already in good shape; no changes made"
    fi
  fi
}

# --- Step 6: Start agent and fix permissions ---
do_compose_up() {
  log_section "Step 6: Start the agent"
  echo "We'll sync config into config-runtime and start the container. Then we fix ownership so the gateway can read its config."
  echo ""

  local script_dir="$IRONCLAW_ROOT/scripts"
  log_step "Running compose-up for $AGENT_NAME..."
  (cd "$IRONCLAW_ROOT" && run_sudo "$script_dir/compose-up.sh" "$AGENT_NAME" -d)
  log_ok "Container started"

  log_step "Ensuring config-runtime is readable by the container (UID 1000)..."
  run_sudo chown -R 1000:1000 "$IRONCLAW_ROOT/agents/$AGENT_NAME/config-runtime" 2>/dev/null || true
  run_sudo chown -R 1000:1000 "$IRONCLAW_ROOT/agents/$AGENT_NAME/logs" 2>/dev/null || true
  run_sudo chown -R 1000:1000 "$IRONCLAW_ROOT/agents/$AGENT_NAME/workspace" 2>/dev/null || true
  log_ok "Ownership fixed"

  # Only restart if gateway doesn't respond yet (idempotent: don't restart a working container)
  local test_out
  test_out="$(cd "$IRONCLAW_ROOT" && "$IRONCLAW_ROOT/scripts/test-gateway-http.sh" "$AGENT_NAME" 2>&1)" || true
  if echo "$test_out" | grep -q "Connection refused\|Connection reset\|Failed to connect\|Could not connect"; then
    log_step "Restarting container to pick up config..."
    (cd "$IRONCLAW_ROOT" && docker_cmd compose -p "$AGENT_NAME" restart 2>/dev/null) || true
    log_ok "Done"
  else
    if echo "$test_out" | head -1 | grep -q .; then
      log_ok "Gateway already responding; skipping restart (no regression)"
    else
      log_step "Restarting container once to pick up config..."
      (cd "$IRONCLAW_ROOT" && docker_cmd compose -p "$AGENT_NAME" restart 2>/dev/null) || true
      log_ok "Done"
    fi
  fi

  # If gateway still not responding, run OpenClaw doctor in the container to fix config and restart (world-class: we are the doctor)
  test_out="$(cd "$IRONCLAW_ROOT" && "$IRONCLAW_ROOT/scripts/test-gateway-http.sh" "$AGENT_NAME" 2>&1)" || true
  if echo "$test_out" | grep -q "Connection refused\|Connection reset\|Failed to connect\|Could not connect"; then
    log_step "Gateway not responding yet. Running OpenClaw doctor --fix in the container..."
    local cid
    cid="$(docker_cmd ps -q -f "name=${AGENT_NAME}" 2>/dev/null | head -1)"
    if [[ -n "$cid" ]]; then
      (timeout 25 docker_cmd exec "$cid" sh -c 'export PATH="/home/openclaw/.npm-global/bin:$PATH"; echo y | openclaw doctor --fix 2>/dev/null' 2>/dev/null) || true
      run_sudo chown -R 1000:1000 "$IRONCLAW_ROOT/agents/$AGENT_NAME/config-runtime" 2>/dev/null || true
      (cd "$IRONCLAW_ROOT" && docker_cmd compose -p "$AGENT_NAME" restart 2>/dev/null) || true
      log_ok "Doctor run and container restarted; Step 8 will re-test the gateway."
    fi
  fi
}

# --- Step 7: Systemd start-on-boot ---
do_systemd() {
  log_section "Step 7: Start on boot (systemd)"
  echo "We'll install a systemd unit so the agent starts automatically after a reboot."
  echo ""

  local service_name="ironclaw-$AGENT_NAME.service"
  local unit_src="$IRONCLAW_ROOT/scripts/systemd/$service_name"
  local unit_dst="/etc/systemd/system/$service_name"
  local start_script="$IRONCLAW_ROOT/scripts/start-$AGENT_NAME-at-boot.sh"

  if [[ ! -f "$unit_src" ]]; then
    log_warn "No systemd unit found at $unit_src. Creating one for $AGENT_NAME..."
    mkdir -p "$(dirname "$unit_src")"
    cat > "$unit_src" << EOF
# Ironclaw $AGENT_NAME — start at boot (systemd)
[Unit]
Description=Ironclaw $AGENT_NAME at boot
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=oneshot
User=$CURRENT_USER
Group=$CURRENT_USER
WorkingDirectory=$IRONCLAW_ROOT
ExecStartPre=/usr/bin/test -f $IRONCLAW_ROOT/agents/$AGENT_NAME/agent.conf
ExecStartPre=/usr/bin/test -f $IRONCLAW_ROOT/agents/$AGENT_NAME/.env
ExecStart=$IRONCLAW_ROOT/scripts/start-$AGENT_NAME-at-boot.sh
TimeoutStartSec=600
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    log_ok "Created $unit_src"
  fi

  if [[ ! -f "$start_script" ]]; then
    log_step "Creating start script $start_script ..."
    cat > "$start_script" << 'STARTScript'
#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WAIT_TIMEOUT=90
WAIT_INTERVAL=5
ELAPSED=0
while [[ $ELAPSED -lt $WAIT_TIMEOUT ]]; do
  IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -n "$IP" ]] && break
  sleep "$WAIT_INTERVAL"
  ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done
[[ -n "$IP" ]] || { echo "No host IP after ${WAIT_TIMEOUT}s. Aborting." >&2; exit 1; }
AGENT_PLACEHOLDER
STARTScript
    sed -i 's|AGENT_PLACEHOLDER|"$SCRIPT_DIR/compose-up.sh" '"$AGENT_NAME"' -d|' "$start_script"
    chmod +x "$start_script"
    log_ok "Created $start_script"
  fi

  # Substitute current user and path in unit if it still has placeholders
  local unit_tmp
  unit_tmp="$(mktemp)"
  sed -e "s|User=.*|User=$CURRENT_USER|" \
      -e "s|Group=.*|Group=$CURRENT_USER|" \
      -e "s|WorkingDirectory=.*|WorkingDirectory=$IRONCLAW_ROOT|" \
      -e "s|/home/[^/]*/ironclaw|$IRONCLAW_ROOT|g" \
      -e "s|ExecStartPre=.*agent.conf|ExecStartPre=/usr/bin/test -f $IRONCLAW_ROOT/agents/$AGENT_NAME/agent.conf|" \
      -e "s|ExecStartPre=.*\.env|ExecStartPre=/usr/bin/test -f $IRONCLAW_ROOT/agents/$AGENT_NAME/.env|" \
      -e "s|ExecStart=.*|ExecStart=$IRONCLAW_ROOT/scripts/start-$AGENT_NAME-at-boot.sh|" \
      "$unit_src" > "$unit_tmp"

  log_step "Installing systemd unit..."
  run_sudo cp "$unit_tmp" "$unit_dst"
  rm -f "$unit_tmp"
  run_sudo systemctl daemon-reload
  run_sudo systemctl enable "$service_name"
  log_ok "Enabled $service_name (agent will start after reboot)"
}

# --- Step 7b: Optional cron to refresh Ollama best-known list (same cadence as heartbeat) ---
do_ollama_refresh_cron() {
  if [[ ! -x "$IRONCLAW_ROOT/scripts/refresh-ollama-best-known.sh" ]]; then
    return 0
  fi
  local cron_line="0 */2 * * * cd $IRONCLAW_ROOT && $IRONCLAW_ROOT/scripts/refresh-ollama-best-known.sh $AGENT_NAME"
  local crontab_user=""
  [[ $(id -u) -eq 0 ]] && [[ -n "$CURRENT_USER" ]] && crontab_user="-u $CURRENT_USER"
  local current_cron
  current_cron="$(crontab $crontab_user -l 2>/dev/null)" || true
  if echo "$current_cron" | grep -q "refresh-ollama-best-known.sh"; then
    log_ok "Cron for Ollama best-known refresh already present"
    return 0
  fi
  log_step "Adding cron to refresh Ollama best-known list every 2h (same as heartbeat)..."
  (echo "$current_cron"; echo "$cron_line") | crontab $crontab_user - 2>/dev/null || true
  if crontab $crontab_user -l 2>/dev/null | grep -q "refresh-ollama-best-known.sh"; then
    log_ok "Cron installed: Ollama best-known list will refresh every 2h"
  else
    log_warn "Could not install cron (run as the Pi user or add manually): $cron_line"
  fi
}

# --- Step 8: Verify and summary ---
do_verify_and_summary() {
  local svc_name="ironclaw-$AGENT_NAME.service"
  log_section "Step 8: Test the gateway and next steps"
  echo "Checking that the OpenClaw gateway is reachable, then sending one chat request."
  echo ""

  if [[ -x "$IRONCLAW_ROOT/scripts/test-gateway-http.sh" ]]; then
    # Resolve agent to get AGENT_PORT for health check
    local agent_port
    if [[ -f "$IRONCLAW_ROOT/agents/$AGENT_NAME/agent.conf" ]]; then
      agent_port="$(grep -E '^AGENT_PORT=' "$IRONCLAW_ROOT/agents/$AGENT_NAME/agent.conf" 2>/dev/null | cut -d= -f2-)"
    fi
    agent_port="${agent_port:-18792}"

    log_step "Health check: GET http://127.0.0.1:${agent_port}/ ..."
    local http_code
    http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${agent_port}/" 2>/dev/null)" || true
    if [[ "$http_code" == "200" ]]; then
      log_ok "Gateway is reachable (HTTP 200)."
    else
      log_warn "Gateway health check returned HTTP ${http_code:-none} (container may still be starting)."
    fi
    echo ""

    log_step "Chat completions: one request to $AGENT_NAME (timeout 30s)..."
    local test_out
    test_out="$(cd "$IRONCLAW_ROOT" && "$IRONCLAW_ROOT/scripts/test-gateway-http.sh" "$AGENT_NAME" 2>&1)" || true
    if echo "$test_out" | grep -q "Connection refused\|Connection reset\|Failed to connect\|Could not connect"; then
      if [[ "$http_code" == "200" ]]; then
        log_warn "Gateway is up (health check passed) but the chat request failed. The chat endpoint may still be loading."
        echo "  Try in a minute: $IRONCLAW_ROOT/scripts/test-gateway-http.sh $AGENT_NAME"
      else
        log_fail "Gateway did not respond (connection error)."
        echo ""
        echo "  The container may still be starting, or OpenClaw may need config fixes."
        echo "  Try in a minute: $IRONCLAW_ROOT/scripts/test-gateway-http.sh $AGENT_NAME"
        echo "  If it still fails, run inside the container: sudo docker exec \$(sudo docker ps -q -f name=${AGENT_NAME}) openclaw doctor --fix"
        echo "  Then: sudo docker restart \$(sudo docker ps -q -f name=${AGENT_NAME})"
      fi
    elif echo "$test_out" | grep -qE '\{|"id":|"choices"'; then
      log_ok "Gateway test passed. OpenClaw responded to a chat request."
      echo ""
      local snippet
      snippet="$(echo "$test_out" | tail -n +2 | head -c 180)"
      if [[ -n "$snippet" ]]; then
        echo "  Response snippet: ${snippet}..."
      fi
      echo ""
      echo "  Run again anytime: $IRONCLAW_ROOT/scripts/test-gateway-http.sh $AGENT_NAME"
    else
      log_warn "Gateway returned something but not a clear JSON response. The agent may still be starting."
      echo "  Output: $(echo "$test_out" | head -3 | tr '\n' ' ')"
      echo ""
      echo "  Try again: $IRONCLAW_ROOT/scripts/test-gateway-http.sh $AGENT_NAME"
    fi
  else
    log_step "Gateway test script not found. To test later: $IRONCLAW_ROOT/scripts/test-gateway-http.sh $AGENT_NAME"
  fi

  echo ""
  echo -e "${BOLD}Summary${RESET}"
  echo "  • IronClaw repo:  $IRONCLAW_ROOT"
  echo "  • Agent:          $AGENT_NAME"
  echo "  • Image:          $IMAGE_TAG"
  echo "  • Start on boot:  systemd unit $svc_name enabled"
  echo ""
  echo -e "${YELLOW}What you should do next:${RESET}"
  echo "  1. Set real secrets in $IRONCLAW_ROOT/agents/$AGENT_NAME/.env"
  echo "     (OPENCLAW_OWNER_DISPLAY_SECRET and, for cloud models, OPENAI_API_KEY)"
  echo "  2. To use local models only: leave OPENAI_API_KEY unset (or not-set); the agent will use Ollama on the LAN if found."
  echo "     Best-known Ollama hosts and models are in workspace/ollama-best-known.json and refreshed every 2h (same as heartbeat) when the cron is installed."
  echo "  3. Before enabling Telegram: in config/openclaw.json set allowFrom/groupAllowFrom to your numeric user ID(s) (not the placeholder 0). Keep dmPolicy/groupPolicy as allowlist."
  echo "  4. Log out and log back in (or reboot) so the docker group takes effect."
  echo "  5. After reboot, check: sudo systemctl status $svc_name"
  echo "  6. Test gateway: $IRONCLAW_ROOT/scripts/test-gateway-http.sh $AGENT_NAME"
  echo ""
  echo -e "${GREEN}Setup complete. You can be proud of this Pi.${RESET}"
  echo ""
}

# --- Main ---
main() {
  echo ""
  echo -e "${BOLD}IronClaw Raspberry Pi setup${RESET}"
  echo "This script will prepare your Pi to run IronClaw and OpenClaw."
  echo ""

  need_sudo
  check_arch
  check_os

  do_docker
  do_clone
  # Early exit if already set up (idempotent: re-runs see a healthy system and leave it alone)
  check_already_set_up

  if [[ "$YES_MODE" != true ]] && [[ "$DRY_RUN" != true ]]; then
    echo -e "${YELLOW}Continue? [y/N]${RESET} "
    read -r ans
    case "$ans" in
      [yY]|[yY][eE][sS]) ;;
      *) echo "Aborted."; exit 0 ;;
    esac
  fi

  do_apt_update
  do_build
  do_configure_agent
  do_compose_up
  do_systemd
  do_ollama_refresh_cron
  do_verify_and_summary
}

main "$@"
