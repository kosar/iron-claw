#!/bin/bash
# Probe autoresearch status for a specific agent.
# Outputs JSON summary of the latest experiment segment.

AGENT_NAME="${AGENT_NAME:-pibot}"
IRONCLAW_ROOT="${IRONCLAW_ROOT:-.}"

# Find the agent's workspace
AGENT_WORKSPACE="$IRONCLAW_ROOT/agents/$AGENT_NAME/workspace"
JSONL_FILE="$AGENT_WORKSPACE/autoresearch.jsonl"

if [ ! -f "$JSONL_FILE" ]; then
    echo '{"ok": true, "enabled": false, "reason": "no autoresearch.jsonl found"}'
    exit 0
fi

# Parse the JSONL file to find the latest config and results
# We use tail to get recent entries and tac to process backwards to find the latest segment
LATEST_RESULTS=$(tail -n 100 "$JSONL_FILE")

# Extract the latest config header
LATEST_CONFIG=$(echo "$LATEST_RESULTS" | grep '"type":"config"' | tail -n 1)
if [ -z "$LATEST_CONFIG" ]; then
    # Fallback if no config line found (legacy or manual start)
    LATEST_CONFIG='{"name":"Unknown Experiment","metricName":"metric","bestDirection":"lower"}'
fi

# Count experiments in the latest segment
# Simplified: count all non-config lines after the last config line
EXPERIMENT_COUNT=$(echo "$LATEST_RESULTS" | sed -n "/$(echo "$LATEST_CONFIG" | sed 's/[^^]/[&]/g; s/\^/\\^/g')/,\$p" | grep -v '"type":"config"' | wc -l | tr -d ' ')

# Get the last result
LAST_RESULT=$(echo "$LATEST_RESULTS" | tail -n 1)
if [[ "$LAST_RESULT" == *"\"type\":\"config\""* ]]; then
    LAST_RESULT='null'
fi

# Find the best result in the latest segment
# (This is a simplified shell-based approach; a full parser would be better but this works for a probe)
BEST_RESULT=$(echo "$LATEST_RESULTS" | sed -n "/$(echo "$LATEST_CONFIG" | sed 's/[^^]/[&]/g; s/\^/\\^/g')/,\$p" | grep -v '"type":"config"' | tail -n 10)

echo "{"
echo "  \"ok\": true,"
echo "  \"enabled\": true,"
echo "  \"agent\": \"$AGENT_NAME\","
echo "  \"config\": $LATEST_CONFIG,"
echo "  \"count\": $EXPERIMENT_COUNT,"
echo "  \"lastResult\": $LAST_RESULT"
echo "}"
