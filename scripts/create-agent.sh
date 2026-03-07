#!/usr/bin/env bash
# create-agent.sh — Scaffold a new agent from the template.
#
# Usage: ./scripts/create-agent.sh <agent-name> [admin-email]
#        ./scripts/create-agent.sh <agent-name> --minimal [admin-email]
#
# Creates agents/{name}/ with a full OpenClaw-defaults skeleton,
# auto-assigns a unique port, and prints a next-steps checklist.
# Use --minimal for a lighter agent (one model, no PiGlow/IR/RFID/camera/productwatcher, etc.).

set -e

BASE="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$BASE/agents/template"
MINIMAL_OPENCLAW="$BASE/scripts/minimal-openclaw.json.tmpl"

MINIMAL=false
NAME=""
ADMIN_EMAIL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --minimal) MINIMAL=true; shift ;;
    *)
      if [[ -z "$NAME" ]]; then
        NAME="$1"
      else
        ADMIN_EMAIL="$1"
      fi
      shift
      ;;
  esac
done
[[ -n "$NAME" ]] || { echo "Usage: $0 <agent-name> [--minimal] [admin-email]" >&2; exit 1; }

# Validate
[[ "$NAME" == "template" ]] && { echo "Error: Cannot create an agent named 'template'" >&2; exit 1; }
[[ -d "$BASE/agents/$NAME" ]] && { echo "Error: Agent '$NAME' already exists in agents/" >&2; exit 1; }
[[ ! -d "$TEMPLATE" ]] && { echo "Error: Template not found at $TEMPLATE" >&2; exit 1; }

# Validate agent name (alphanumeric + hyphens only)
if [[ ! "$NAME" =~ ^[a-zA-Z][a-zA-Z0-9-]*$ ]]; then
  echo "Error: Agent name must start with a letter and contain only letters, numbers, and hyphens" >&2
  exit 1
fi

# Auto-assign port: scan existing agent.conf files for AGENT_PORT, pick max + 1
MAX_PORT=18789
for conf in "$BASE"/agents/*/agent.conf; do
  [[ -f "$conf" ]] || continue
  port=$(grep -E '^AGENT_PORT=' "$conf" 2>/dev/null | cut -d= -f2)
  [[ -n "$port" ]] && (( port > MAX_PORT )) && MAX_PORT=$port
done
PORT=$((MAX_PORT + 1))

echo "Creating agent '$NAME' (port $PORT)..."

# Copy template
cp -R "$TEMPLATE" "$BASE/agents/$NAME"

# Write agent.conf
cat > "$BASE/agents/$NAME/agent.conf" <<EOF
# agent.conf — ${NAME} deployment configuration
AGENT_NAME=${NAME}
AGENT_PORT=${PORT}
AGENT_CONTAINER=${NAME}_secure
AGENT_MEM_LIMIT=4g
AGENT_CPUS=2.0
AGENT_SHM_SIZE=128m
EOF

# OpenClaw config: use minimal template or full template
if [[ "$MINIMAL" == true ]] && [[ -f "$MINIMAL_OPENCLAW" ]]; then
  sed "s/{{PORT}}/$PORT/g" "$MINIMAL_OPENCLAW" | sed 's/\${TELEGRAM_BOT_TOKEN}/not-configured/g' > "$BASE/agents/$NAME/config/openclaw.json"
else
  # Replace {{PORT}} in openclaw.json (text replacement since template has non-JSON placeholder)
  sed -i.bak "s/{{PORT}}/$PORT/g" "$BASE/agents/$NAME/config/openclaw.json"
  rm -f "$BASE/agents/$NAME/config/openclaw.json.bak"
  # Set Telegram botToken to a safe placeholder (OpenClaw crashes on missing env vars)
  sed -i.bak 's/\${TELEGRAM_BOT_TOKEN}/not-configured/g' "$BASE/agents/$NAME/config/openclaw.json"
  rm -f "$BASE/agents/$NAME/config/openclaw.json.bak"
fi

# Replace {{NAME}} in workspace files
sed -i.bak "s/{{NAME}}/$NAME/g" "$BASE/agents/$NAME/workspace/IDENTITY.md"
rm -f "$BASE/agents/$NAME/workspace/IDENTITY.md.bak"

# Replace model placeholder with OpenAI default
sed -i.bak "s/{{MODEL_DESCRIPTION}}/GPT-5-mini (OpenAI), fallback: Qwen3 8B (local Ollama)/g" "$BASE/agents/$NAME/workspace/IDENTITY.md"
rm -f "$BASE/agents/$NAME/workspace/IDENTITY.md.bak"

sed -i.bak "s/{{NAME}}/$NAME/g" "$BASE/agents/$NAME/workspace/TODO.md"
rm -f "$BASE/agents/$NAME/workspace/TODO.md.bak"

# Replace model-related placeholders with OpenAI defaults
sed -i.bak "s/{{API_KEY_REQUIREMENT}}/and an OPENAI_API_KEY (or configure me for Ollama-only)/g" "$BASE/agents/$NAME/workspace/TODO.md"
rm -f "$BASE/agents/$NAME/workspace/TODO.md.bak"

sed -i.bak "s|^{{API_KEY_REQUIRED_LINE}}$|- \`OPENAI_API_KEY\` — for cloud LLM access (or remove openai from my model config)|g" "$BASE/agents/$NAME/workspace/TODO.md"
rm -f "$BASE/agents/$NAME/workspace/TODO.md.bak"

# Replace .env.example cloud key placeholder (line-by-line for macOS sed compat)
sed -i.bak '/^{{CLOUD_API_KEY_LINE}}$/c\
# Required for cloud LLM (or configure Ollama-only in openclaw.json):\
OPENAI_API_KEY=' "$BASE/agents/$NAME/.env.example"
rm -f "$BASE/agents/$NAME/.env.example.bak"

# Replace {{DATE}} with today's date
TODAY=$(date +%Y-%m-%d)
sed -i.bak "s/{{DATE}}/$TODAY/g" "$BASE/agents/$NAME/workspace/TODO.md"
rm -f "$BASE/agents/$NAME/workspace/TODO.md.bak"

# Handle admin email
if [[ -n "$ADMIN_EMAIL" ]]; then
  sed -i.bak "s/{{ADMIN_EMAIL}}/$ADMIN_EMAIL/g" "$BASE/agents/$NAME/workspace/TODO.md"
  rm -f "$BASE/agents/$NAME/workspace/TODO.md.bak"

  # Seed USER.md with admin email
  cat > "$BASE/agents/$NAME/workspace/USER.md" <<EOF
# USER.md - About Your Human

- **Contact:** ${ADMIN_EMAIL}
- **Role:** Owner/Administrator

_Fill in the rest — name, timezone, preferences, interests._
EOF
else
  sed -i.bak "s/{{ADMIN_EMAIL}}/(not set)/g" "$BASE/agents/$NAME/workspace/TODO.md"
  rm -f "$BASE/agents/$NAME/workspace/TODO.md.bak"
fi

# Copy .env.example → .env
cp "$BASE/agents/$NAME/.env.example" "$BASE/agents/$NAME/.env"

# If admin email is known, seed internal learning feedback recipient.
if [[ -n "$ADMIN_EMAIL" ]]; then
  if grep -q '^LEARNING_FEEDBACK_EMAIL=' "$BASE/agents/$NAME/.env"; then
    sed -i.bak "s/^LEARNING_FEEDBACK_EMAIL=.*/LEARNING_FEEDBACK_EMAIL=$ADMIN_EMAIL/g" "$BASE/agents/$NAME/.env"
    rm -f "$BASE/agents/$NAME/.env.bak"
  else
    echo "LEARNING_FEEDBACK_EMAIL=$ADMIN_EMAIL" >> "$BASE/agents/$NAME/.env"
  fi
fi

# Remove template-only files from the new agent
rm -f "$BASE/agents/$NAME/.env.example"
rm -f "$BASE/agents/$NAME/agent.conf.example"

# Create logs directory
mkdir -p "$BASE/agents/$NAME/logs"

# Minimal: remove integration-heavy workspace dirs and skills so the agent stays light
if [[ "$MINIMAL" == true ]]; then
  for dir in audio piglow piface camera rfid ir-codes; do
    rm -rf "$BASE/agents/$NAME/workspace/$dir"
  done
  for skill in productwatcher four-agreements rfid-reader piglow-signal piface-display image-vision ir-blast camera-capture audio-capture pdf-reader restaurant-scout image-gen daily-report; do
    rm -rf "$BASE/agents/$NAME/workspace/skills/$skill"
  done
fi

echo ""
echo "Agent '$NAME' created at agents/$NAME/"
[[ "$MINIMAL" == true ]] && echo "(Minimal agent — reduced skills and config)"
echo ""
echo "Next steps:"
echo "  1. Edit agents/$NAME/.env — set OPENCLAW_GATEWAY_TOKEN and OPENAI_API_KEY"
if [[ "$MINIMAL" != true ]]; then
  echo "     Optional: add BRAVE_API_KEY to enable web search + restaurant-scout skill"
  echo "     (then flip tools.web.search.enabled + skills.entries.restaurant-scout.enabled in config/openclaw.json)"
fi
if [[ -n "$ADMIN_EMAIL" ]]; then
  echo "     (Admin email: $ADMIN_EMAIL — set SMTP_FROM_EMAIL and GMAIL_APP_PASSWORD for onboarding emails)"
  echo "     (LEARNING_FEEDBACK_EMAIL was seeded to admin email for owner-only quality feedback)"
  echo "     (Set LEARNING_FEEDBACK_EMAIL_MODE=digest for periodic digest delivery)"
else
  echo "     (No admin email set — onboarding status will be logged to workspace/onboarding-log.md)"
fi
echo "  2. Customize agents/$NAME/workspace/ — IDENTITY.md, SOUL.md, USER.md"
echo "  3. Optionally configure channels in agents/$NAME/config/openclaw.json"
echo "  4. Start: ./scripts/compose-up.sh $NAME -d"
echo "  5. Test:  ./scripts/test-gateway-http.sh $NAME"
echo ""
echo "Resource defaults: 4g RAM, 2 CPUs, 128m SHM (edit agents/$NAME/agent.conf to change)"
echo "Port: $PORT"
echo ""
echo "(Tip: Use ./scripts/forge-agent.sh for interactive model selection)"
