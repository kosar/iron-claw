#!/usr/bin/env bash
# switch-tier.sh — Runtime model switcher for IronClaw agents.
# Usage: bash switch-tier.sh <tier> [task_type] [reason]
#   tier: flagship, worker, efficiency, reasoning, coding
#   task_type: primary, heartbeat (default: primary)
#   reason: "for complex task", "to save cost", etc.
# Requires: python3 (no jq dependency)

TIER="$1"
TASK="${2:-primary}"
REASON="${3:-User/Agent requested switch}"

AGENT_DIR="/home/ai_sandbox/.openclaw"
CONFIG_FILE="$AGENT_DIR/openclaw.json"
TIERS_FILE="$AGENT_DIR/workspace/skills/llm-manager/tiers.json"
LOG_FILE="/tmp/openclaw/model_switches.log"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Config file not found at $CONFIG_FILE"
  exit 1
fi

if [[ ! -f "$TIERS_FILE" ]]; then
  echo "Error: Tier map not found at $TIERS_FILE"
  exit 1
fi

# Look up model for this tier using python3
MODEL=$(python3 -c "
import json, sys
data = json.load(open('$TIERS_FILE'))
tier = '$TIER'
model = data['tiers'].get(tier)
if model:
    print(model)
else:
    tiers = ', '.join(data['tiers'].keys())
    print(f'ERROR:No model for tier \"{tier}\". Available: {tiers}', file=sys.stderr)
    sys.exit(1)
" 2>&1)

if [[ $? -ne 0 ]] || [[ "$MODEL" == ERROR:* ]]; then
  echo "Error: ${MODEL#ERROR:}"
  exit 1
fi

# Perform update based on task type using python3
case "$TASK" in
  primary|heartbeat)
    RESULT=$(python3 -c "
import json, sys, shutil

config_file = '$CONFIG_FILE'
task = '$TASK'
model = '$MODEL'

with open(config_file, 'r') as f:
    config = json.load(f)

if task == 'primary':
    old = config['agents']['defaults']['model']['primary']
    config['agents']['defaults']['model']['primary'] = model
elif task == 'heartbeat':
    old = config['agents']['defaults'].get('heartbeat', {}).get('model', 'none')
    if 'heartbeat' not in config['agents']['defaults']:
        config['agents']['defaults']['heartbeat'] = {}
    config['agents']['defaults']['heartbeat']['model'] = model

# Write atomically
tmp = config_file + '.tmp'
with open(tmp, 'w') as f:
    json.dump(config, f, indent=2)
import os; os.replace(tmp, config_file)
print(old)
" 2>&1)
    if [[ $? -ne 0 ]]; then
      echo "Error updating config: $RESULT"
      exit 1
    fi
    OLD_MODEL="$RESULT"
    ;;
  *)
    echo "Error: Unknown task type '$TASK'. Use: primary, heartbeat"
    exit 1
    ;;
esac

# Log it
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p "$(dirname "$LOG_FILE")"
printf '{"time": "%s", "task": "%s", "tier": "%s", "old_model": "%s", "new_model": "%s", "reason": "%s"}\n' \
  "$TIMESTAMP" "$TASK" "$TIER" "$OLD_MODEL" "$MODEL" "$REASON" >> "$LOG_FILE"

echo "Switched $TASK to $TIER ($MODEL). Reason: $REASON"
echo "Note: Change takes effect immediately via config hot-reload. Resets on agent restart."
