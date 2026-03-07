#!/usr/bin/env bash
# forge-agent.sh — Interactive agent generator with model catalog + image gen.
#
# Usage:
#   ./scripts/forge-agent.sh                              # interactive
#   ./scripts/forge-agent.sh --name foo --model kimi-k25  # non-interactive
#   ./scripts/forge-agent.sh --name foo --model kimi-k25 --email admin@example.com
#
# Creates a fully configured agent from the template with the selected model
# profile, auto-generated gateway token, and LAN Ollama discovery.

set -e

BASE="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$BASE/agents/template"
PROFILES_DIR="$BASE/scripts/model-profiles"
DISCOVER_SCRIPT="$BASE/scripts/discover-ollama.sh"

# --- Require jq ---
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  echo "  macOS:  brew install jq" >&2
  echo "  Linux:  apt install jq  OR  yum install jq" >&2
  exit 1
fi

# --- Parse CLI flags ---
ARG_NAME="" ARG_MODEL="" ARG_EMAIL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)  ARG_NAME="$2"; shift 2 ;;
    --model) ARG_MODEL="$2"; shift 2 ;;
    --email) ARG_EMAIL="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--name <agent-name>] [--model <profile-id>] [--email <admin-email>]"
      echo ""
      echo "Available model profiles:"
      for f in "$PROFILES_DIR"/*.json; do
        id=$(jq -r '.meta.id' "$f")
        name=$(jq -r '.meta.name' "$f")
        cost=$(jq -r '.meta.cost_tier' "$f")
        printf "  %-20s %s (%s)\n" "$id" "$name" "$cost"
      done
      exit 0
      ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# --- UI helpers ---
BOLD="\033[1m" DIM="\033[2m" GREEN="\033[32m" CYAN="\033[36m" YELLOW="\033[33m" RESET="\033[0m"

banner() {
  echo ""
  echo -e "${BOLD}  ╔══════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}  ║     IRONCLAW — AGENT FORGE           ║${RESET}"
  echo -e "${BOLD}  ╚══════════════════════════════════════╝${RESET}"
  echo ""
}

step() { echo -e "  ${BOLD}>>>${RESET} $1"; }
ok()   { echo -e "   ${GREEN}✓${RESET}  $1"; }
info() { echo -e "   ${DIM}$1${RESET}"; }

# --- Load model profiles ---
PROFILE_FILES=()
PROFILE_IDS=()
PROFILE_NAMES=()
PROFILE_DESCS=()
PROFILE_COSTS=()

for f in "$PROFILES_DIR"/*.json; do
  [[ -f "$f" ]] || continue
  PROFILE_FILES+=("$f")
  PROFILE_IDS+=($(jq -r '.meta.id' "$f"))
  PROFILE_NAMES+=($(jq -r '.meta.name' "$f"))
  PROFILE_DESCS+=("$(jq -r '.meta.description' "$f")")
  PROFILE_COSTS+=($(jq -r '.meta.cost_tier' "$f"))
done

if [[ ${#PROFILE_FILES[@]} -eq 0 ]]; then
  echo "Error: No model profiles found in $PROFILES_DIR" >&2
  exit 1
fi

# --- Interactive prompts (skip if flags provided) ---

# Model selection
PROFILE_FILE=""
if [[ -n "$ARG_MODEL" ]]; then
  for i in "${!PROFILE_IDS[@]}"; do
    [[ "${PROFILE_IDS[$i]}" == "$ARG_MODEL" ]] && PROFILE_FILE="${PROFILE_FILES[$i]}" && break
  done
  [[ -z "$PROFILE_FILE" ]] && { echo "Error: Unknown model profile '$ARG_MODEL'" >&2; exit 1; }
else
  banner
  echo -e "  ${BOLD}Select a model:${RESET}"
  echo ""
  for i in "${!PROFILE_IDS[@]}"; do
    COST="${PROFILE_COSTS[$i]}"
    [[ "$COST" == "free" ]] && COST_DISPLAY="free" || COST_DISPLAY="$COST"
    printf "    ${BOLD}[%d]${RESET} %-28s %-6s %s\n" $((i+1)) "${PROFILE_NAMES[$i]}" "$COST_DISPLAY" "${PROFILE_DESCS[$i]}"
  done
  echo ""
  read -rp "  Choice [1]: " CHOICE
  CHOICE="${CHOICE:-1}"
  IDX=$((CHOICE - 1))
  if [[ $IDX -lt 0 || $IDX -ge ${#PROFILE_FILES[@]} ]]; then
    echo "Error: Invalid choice" >&2; exit 1
  fi
  PROFILE_FILE="${PROFILE_FILES[$IDX]}"
fi

# Agent name
if [[ -z "$ARG_NAME" ]]; then
  echo ""
  read -rp "  Agent name: " ARG_NAME
  [[ -z "$ARG_NAME" ]] && { echo "Error: Agent name is required" >&2; exit 1; }
fi
NAME="$ARG_NAME"

# Email
if [[ -z "$ARG_EMAIL" && -t 0 ]]; then
  read -rp "  Admin email (optional): " ARG_EMAIL
fi
ADMIN_EMAIL="$ARG_EMAIL"

# --- Validate ---
[[ "$NAME" == "template" ]] && { echo "Error: Cannot create an agent named 'template'" >&2; exit 1; }
[[ -d "$BASE/agents/$NAME" ]] && { echo "Error: Agent '$NAME' already exists in agents/" >&2; exit 1; }
[[ ! -d "$TEMPLATE" ]] && { echo "Error: Template not found at $TEMPLATE" >&2; exit 1; }
if [[ ! "$NAME" =~ ^[a-zA-Z][a-zA-Z0-9-]*$ ]]; then
  echo "Error: Agent name must start with a letter and contain only letters, numbers, and hyphens" >&2
  exit 1
fi

# --- Load profile data ---
PROFILE_ID=$(jq -r '.meta.id' "$PROFILE_FILE")
PROFILE_NAME=$(jq -r '.meta.name' "$PROFILE_FILE")
REQUIRES_KEY=$(jq -r '.meta.requires_api_key' "$PROFILE_FILE")
ENV_VAR=$(jq -r '.meta.env_var // empty' "$PROFILE_FILE")
ENV_LABEL=$(jq -r '.meta.env_label // empty' "$PROFILE_FILE")
ENV_HINT=$(jq -r '.meta.env_hint // empty' "$PROFILE_FILE")
PRIMARY=$(jq -r '.agent_defaults.primary' "$PROFILE_FILE")
FALLBACKS=$(jq -c '.agent_defaults.fallbacks' "$PROFILE_FILE")
HEARTBEAT=$(jq -r '.agent_defaults.heartbeat_model' "$PROFILE_FILE")
MODEL_DESC=$(jq -r '.identity_model_line' "$PROFILE_FILE")

# Image gen settings
IMG_ENDPOINT=$(jq -r '.image_gen.provider_endpoint // empty' "$PROFILE_FILE")
IMG_ENV_VAR=$(jq -r '.image_gen.provider_env_var // empty' "$PROFILE_FILE")

# --- Auto-assign port ---
MAX_PORT=18789
for conf in "$BASE"/agents/*/agent.conf; do
  [[ -f "$conf" ]] || continue
  port=$(grep -E '^AGENT_PORT=' "$conf" 2>/dev/null | cut -d= -f2)
  [[ -n "$port" ]] && (( port > MAX_PORT )) && MAX_PORT=$port
done
PORT=$((MAX_PORT + 1))

# --- Generate gateway token ---
if command -v openssl &>/dev/null; then
  GW_TOKEN=$(openssl rand -hex 24)
else
  GW_TOKEN=$(head -c 24 /dev/urandom | xxd -p)
fi
GW_TOKEN_SHORT="${GW_TOKEN:0:8}...${GW_TOKEN: -4}"

echo ""

# --- Step 1: Copy template ---
step "Copying template to agents/$NAME/"
cp -R "$TEMPLATE" "$BASE/agents/$NAME"
ok "Template copied"

# --- Step 2: Write agent.conf ---
step "Writing agent.conf (port $PORT)"
cat > "$BASE/agents/$NAME/agent.conf" <<EOF
# agent.conf — ${NAME} deployment configuration
AGENT_NAME=${NAME}
AGENT_PORT=${PORT}
AGENT_CONTAINER=${NAME}_secure
AGENT_MEM_LIMIT=4g
AGENT_CPUS=2.0
AGENT_SHM_SIZE=128m
EOF
ok "agent.conf written"

# --- Step 3: Patch model configuration ---
step "Patching model configuration ($PROFILE_NAME)"

AGENT_DIR="$BASE/agents/$NAME"
OC_JSON="$AGENT_DIR/config/openclaw.json"
MODELS_JSON="$AGENT_DIR/config/agents/main/agent/models.json"
AUTH_JSON="$AGENT_DIR/config/agents/main/agent/auth-profiles.json"

# Replace {{PORT}} in openclaw.json
sed -i.bak "s/{{PORT}}/$PORT/g" "$OC_JSON"
rm -f "$OC_JSON.bak"

# --- Patch openclaw.json ---
# If profile has cloud providers, merge them in; if ollama-only, strip cloud providers
if [[ "$PROFILE_ID" == "ollama-local" ]]; then
  # Remove openai provider, keep only ollama
  jq '.models.providers = {ollama: .models.providers.ollama}' "$OC_JSON" > "$OC_JSON.tmp" && mv "$OC_JSON.tmp" "$OC_JSON"
else
  # Strip non-ollama providers first (remove default openai)
  jq '.models.providers = {ollama: .models.providers.ollama}' "$OC_JSON" > "$OC_JSON.tmp" && mv "$OC_JSON.tmp" "$OC_JSON"
  # Merge in the profile's cloud provider
  CLOUD_PROVIDERS=$(jq -c '.providers' "$PROFILE_FILE")
  jq --argjson cp "$CLOUD_PROVIDERS" '.models.providers += $cp' "$OC_JSON" > "$OC_JSON.tmp" && mv "$OC_JSON.tmp" "$OC_JSON"
fi

# Set Telegram botToken to a safe literal placeholder (OpenClaw crashes on missing env vars)
# Users will replace this with a real token when they configure Telegram
jq '.channels.telegram.botToken = "not-configured"' "$OC_JSON" > "$OC_JSON.tmp" && mv "$OC_JSON.tmp" "$OC_JSON"

# Set agent defaults
jq --arg p "$PRIMARY" --argjson f "$FALLBACKS" --arg h "$HEARTBEAT" '
  .agents.defaults.model.primary = $p |
  .agents.defaults.model.fallbacks = $f |
  .agents.defaults.heartbeat.model = $h
' "$OC_JSON" > "$OC_JSON.tmp" && mv "$OC_JSON.tmp" "$OC_JSON"

ok "openclaw.json — provider injected, agent defaults set"

# --- Patch models.json ---
if [[ "$PROFILE_ID" == "ollama-local" ]]; then
  jq '.providers = {ollama: .providers.ollama}' "$MODELS_JSON" > "$MODELS_JSON.tmp" && mv "$MODELS_JSON.tmp" "$MODELS_JSON"
else
  jq '.providers = {ollama: .providers.ollama}' "$MODELS_JSON" > "$MODELS_JSON.tmp" && mv "$MODELS_JSON.tmp" "$MODELS_JSON"
  CLOUD_PROVIDERS=$(jq -c '.providers' "$PROFILE_FILE")
  jq --argjson cp "$CLOUD_PROVIDERS" '.providers += $cp' "$MODELS_JSON" > "$MODELS_JSON.tmp" && mv "$MODELS_JSON.tmp" "$MODELS_JSON"
fi

ok "models.json — pricing registered"

# --- Patch auth-profiles.json ---
if [[ "$PROFILE_ID" == "ollama-local" ]]; then
  # Keep only ollama auth
  jq '{profiles: {"ollama:default": .profiles["ollama:default"]}, order: {ollama: .order.ollama}}' "$AUTH_JSON" > "$AUTH_JSON.tmp" && mv "$AUTH_JSON.tmp" "$AUTH_JSON"
else
  # Strip non-ollama, add profile's auth
  AUTH_KEY=$(jq -r '.auth_profile.key' "$PROFILE_FILE")
  AUTH_PROFILE=$(jq -c '.auth_profile.profile' "$PROFILE_FILE")
  ORDER_KEY=$(jq -r '.auth_profile.order_key' "$PROFILE_FILE")
  ORDER_VALUE=$(jq -c '.auth_profile.order_value' "$PROFILE_FILE")

  jq --arg ak "$AUTH_KEY" --argjson ap "$AUTH_PROFILE" --arg ok_ "$ORDER_KEY" --argjson ov "$ORDER_VALUE" '
    {
      profiles: {
        "ollama:default": .profiles["ollama:default"],
        ($ak): $ap
      },
      order: {
        ollama: .order.ollama,
        ($ok_): $ov
      }
    }
  ' "$AUTH_JSON" > "$AUTH_JSON.tmp" && mv "$AUTH_JSON.tmp" "$AUTH_JSON"
fi

ok "auth-profiles.json — auth profile configured"

# --- Step 4: Generate .env ---
step "Generating .env"

{
  echo "# .env — $NAME secrets (never commit this file)"
  echo ""
  echo "# Gateway auth token (auto-generated):"
  echo "OPENCLAW_GATEWAY_TOKEN=$GW_TOKEN"
  echo ""
  if [[ "$REQUIRES_KEY" == "true" && -n "$ENV_VAR" ]]; then
    echo "# Required for cloud LLM — $ENV_LABEL:"
    echo "# $ENV_HINT"
    echo "$ENV_VAR="
  else
    echo "# No cloud API key needed — running Ollama-only"
  fi
  echo ""
  echo "# Optional — Telegram bot (create via @BotFather):"
  echo "TELEGRAM_BOT_TOKEN="
  echo ""
  echo "# Email (SMTP via Gmail) — used for admin notifications"
  echo "SMTP_FROM_EMAIL="
  echo "GMAIL_APP_PASSWORD="
  echo ""
  echo "# Internal learning feedback (owner-only, never user-visible)"
  if [[ -n "$ADMIN_EMAIL" ]]; then
    echo "LEARNING_FEEDBACK_EMAIL=$ADMIN_EMAIL"
  else
    echo "LEARNING_FEEDBACK_EMAIL="
  fi
  echo "LEARNING_FEEDBACK_EMAIL_MODE=immediate"
  echo "LEARNING_FEEDBACK_DIGEST_MIN_RUNS=10"
  echo "LEARNING_FEEDBACK_DIGEST_MINUTES=120"
  echo "LEARNING_FEEDBACK_DISABLE_LLM_JUDGE=false"
  # Image gen env vars if applicable
  if [[ -n "$IMG_ENDPOINT" && -n "$IMG_ENV_VAR" ]]; then
    echo ""
    echo "# Image generation (cloud fallback):"
    echo "MODEL_PROVIDER_IMAGE_URL=$IMG_ENDPOINT"
    echo "MODEL_PROVIDER_IMAGE_KEY=\${$IMG_ENV_VAR}"
  fi
} > "$AGENT_DIR/.env"

ok "Gateway token auto-generated"
if [[ "$REQUIRES_KEY" == "true" && -n "$ENV_VAR" ]]; then
  ok "$ENV_VAR placeholder ready"
else
  ok "No cloud API key needed"
fi

# --- Step 5: Personalize workspace ---
step "Personalizing workspace"

# Replace {{NAME}}
sed -i.bak "s/{{NAME}}/$NAME/g" "$AGENT_DIR/workspace/IDENTITY.md"
rm -f "$AGENT_DIR/workspace/IDENTITY.md.bak"

# Replace {{MODEL_DESCRIPTION}}
sed -i.bak "s|{{MODEL_DESCRIPTION}}|$MODEL_DESC|g" "$AGENT_DIR/workspace/IDENTITY.md"
rm -f "$AGENT_DIR/workspace/IDENTITY.md.bak"

ok "IDENTITY.md — model description set"

# Replace {{NAME}} and {{DATE}} in TODO.md
sed -i.bak "s/{{NAME}}/$NAME/g" "$AGENT_DIR/workspace/TODO.md"
rm -f "$AGENT_DIR/workspace/TODO.md.bak"

TODAY=$(date +%Y-%m-%d)
sed -i.bak "s/{{DATE}}/$TODAY/g" "$AGENT_DIR/workspace/TODO.md"
rm -f "$AGENT_DIR/workspace/TODO.md.bak"

# Handle admin email
if [[ -n "$ADMIN_EMAIL" ]]; then
  sed -i.bak "s/{{ADMIN_EMAIL}}/$ADMIN_EMAIL/g" "$AGENT_DIR/workspace/TODO.md"
  rm -f "$AGENT_DIR/workspace/TODO.md.bak"
  cat > "$AGENT_DIR/workspace/USER.md" <<EOF
# USER.md - About Your Human

- **Contact:** ${ADMIN_EMAIL}
- **Role:** Owner/Administrator

_Fill in the rest — name, timezone, preferences, interests._
EOF
else
  sed -i.bak "s/{{ADMIN_EMAIL}}/(not set)/g" "$AGENT_DIR/workspace/TODO.md"
  rm -f "$AGENT_DIR/workspace/TODO.md.bak"
fi

# Replace API key placeholders in TODO.md
if [[ "$REQUIRES_KEY" == "true" && -n "$ENV_VAR" ]]; then
  sed -i.bak "s|{{API_KEY_REQUIREMENT}}|and a $ENV_VAR|g" "$AGENT_DIR/workspace/TODO.md"
  rm -f "$AGENT_DIR/workspace/TODO.md.bak"
  sed -i.bak "s|^{{API_KEY_REQUIRED_LINE}}$|- \`$ENV_VAR\` — for cloud LLM access ($ENV_HINT)|g" "$AGENT_DIR/workspace/TODO.md"
  rm -f "$AGENT_DIR/workspace/TODO.md.bak"
else
  sed -i.bak "s|{{API_KEY_REQUIREMENT}}|(no cloud API key needed for Ollama-only)|g" "$AGENT_DIR/workspace/TODO.md"
  rm -f "$AGENT_DIR/workspace/TODO.md.bak"
  sed -i.bak "s|^{{API_KEY_REQUIRED_LINE}}$|- No cloud API key needed — running Ollama-only|g" "$AGENT_DIR/workspace/TODO.md"
  rm -f "$AGENT_DIR/workspace/TODO.md.bak"
fi

# Replace .env.example cloud key placeholder
if [[ -f "$AGENT_DIR/.env.example" ]]; then
  if [[ "$REQUIRES_KEY" == "true" && -n "$ENV_VAR" ]]; then
    sed -i.bak '/^{{CLOUD_API_KEY_LINE}}$/c\
# Required for cloud LLM ('"$ENV_LABEL"'):\
'"$ENV_VAR"'=' "$AGENT_DIR/.env.example"
  else
    sed -i.bak 's|^{{CLOUD_API_KEY_LINE}}$|# No cloud API key needed — running Ollama-only|g' "$AGENT_DIR/.env.example"
  fi
  rm -f "$AGENT_DIR/.env.example.bak"
fi

ok "TODO.md — onboarding checklist customized"

# --- Step 6: LAN Ollama Discovery ---
step "Scanning LAN for Ollama servers..."

OLLAMA_HOSTS_FILE="$AGENT_DIR/workspace/skills/image-gen/ollama-hosts.json"
if [[ -x "$DISCOVER_SCRIPT" ]]; then
  # Capture scan output (stderr has progress, stdout has nothing since we write to file)
  SCAN_OUTPUT=$(bash "$DISCOVER_SCRIPT" "$OLLAMA_HOSTS_FILE" 2>&1) || true

  if [[ -f "$OLLAMA_HOSTS_FILE" ]]; then
    HOST_COUNT=$(jq '.hosts | length' "$OLLAMA_HOSTS_FILE" 2>/dev/null || echo 0)
    IMAGE_COUNT=$(jq '[.image_capable[]?.models[]?] | length' "$OLLAMA_HOSTS_FILE" 2>/dev/null || echo 0)
    SUBNET_DISPLAY=$(jq -r '.subnet // "unknown"' "$OLLAMA_HOSTS_FILE" 2>/dev/null || echo "unknown")

    if [[ "$HOST_COUNT" -gt 0 ]]; then
      ok "Found $HOST_COUNT Ollama server(s) on $SUBNET_DISPLAY"
      # Show each host
      jq -r '.hosts[] | "       \(.host)  Ollama \(.version)  \(.all_models | join(", "))"' "$OLLAMA_HOSTS_FILE" 2>/dev/null | while read -r line; do
        info "$line"
      done
      if [[ "$IMAGE_COUNT" -gt 0 ]]; then
        IMG_HOST_COUNT=$(jq '.image_capable | length' "$OLLAMA_HOSTS_FILE" 2>/dev/null || echo 0)
        ok "Image gen: $IMG_HOST_COUNT host(s) with $IMAGE_COUNT image model(s)"
      else
        info "No image gen models found (install with: ollama pull x/flux2-klein)"
      fi
    else
      info "No Ollama servers found on LAN (image gen will use cloud fallback)"
    fi
    # Rewrite localhost/127.0.0.1 → host.docker.internal for container reachability
    # Containers can't reach the host via 127.0.0.1 (that's the container's own loopback)
    jq '
      def remap: if . == "127.0.0.1" or . == "localhost" then "host.docker.internal" else . end;
      .hosts = [.hosts[] | .host = (.host | remap)] |
      .image_capable = [.image_capable[]? | .host = (.host | remap)] |
      .text_capable = [.text_capable[]? | .host = (.host | remap)] |
      .hosts = [.hosts | group_by(.host)[] | first] |
      .image_capable = [.image_capable | group_by(.host)[]? | first] |
      .text_capable = [.text_capable | group_by(.host)[]? | first]
    ' "$OLLAMA_HOSTS_FILE" > "$OLLAMA_HOSTS_FILE.tmp" && mv "$OLLAMA_HOSTS_FILE.tmp" "$OLLAMA_HOSTS_FILE"

    ok "ollama-hosts.json seeded (localhost → host.docker.internal for container access)"
  else
    info "LAN scan completed but no hosts file written"
  fi
else
  info "discover-ollama.sh not found — skipping LAN scan"
fi

# --- Step 7: Cleanup ---
step "Cleaning up"
rm -f "$AGENT_DIR/.env.example"
rm -f "$AGENT_DIR/agent.conf.example"
mkdir -p "$AGENT_DIR/logs"
ok "Template artifacts removed, logs/ created"

# --- Summary ---
echo ""
echo -e "  ${BOLD}══════════════════════════════════════${RESET}"
echo -e "   ${GREEN}${BOLD}FORGED: $NAME${RESET}"
echo -e "  ${BOLD}══════════════════════════════════════${RESET}"
echo -e "   Model:    $PROFILE_NAME"
echo -e "   Port:     $PORT"
echo -e "   Token:    $GW_TOKEN_SHORT (auto-generated)"
echo -e "   Location: agents/$NAME/"
echo ""
if [[ "$REQUIRES_KEY" == "true" && -n "$ENV_VAR" ]]; then
  echo -e "   ${YELLOW}TODO: Set your $ENV_LABEL:${RESET}"
  [[ -n "$ENV_HINT" ]] && echo -e "     → $ENV_HINT"
  echo -e "     → echo '$ENV_VAR=sk-...' >> agents/$NAME/.env"
  echo ""
fi
echo -e "   Start:  ./scripts/compose-up.sh $NAME -d"
echo -e "   Test:   ./scripts/test-gateway-http.sh $NAME"
echo -e "   Logs:   ./scripts/watch-logs.sh $NAME"
echo -e "  ${BOLD}══════════════════════════════════════${RESET}"
echo ""
