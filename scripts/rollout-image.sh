#!/usr/bin/env bash
# rollout-image.sh — Rebuild the ironclaw image and roll it out to all agents.
#
# Usage: ./scripts/rollout-image.sh
#
# Rebuilds the Docker image (ironclaw:2.0), then runs compose-up.sh -d for every
# agent listed by list_agent_dirs so each agent uses the new image.
# Agent state in config-runtime/ is preserved.

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Repo root (list_agent_dirs needs to be called from a script that has lib.sh sourced;
# we need IRONCLAW_ROOT for the build and compose-up)
BASE="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_TAG="${IRONCLAW_IMAGE_TAG:-ironclaw:2.0}"

echo "Rebuilding image: $IMAGE_TAG"
docker build -t "$IMAGE_TAG" "$BASE"

AGENTS=()
while IFS= read -r name; do
  [[ -n "$name" ]] && AGENTS+=("$name")
done < <(list_agent_dirs)

if [[ ${#AGENTS[@]} -eq 0 ]]; then
  echo "No agents found. Create one with ./scripts/create-agent.sh <name>"
  exit 0
fi

echo "Rolling out to ${#AGENTS[@]} agent(s): ${AGENTS[*]}"
for name in "${AGENTS[@]}"; do
  echo "── $name ──"
  "$SCRIPT_DIR/compose-up.sh" "$name" -d
  echo ""
done

echo "Rollout complete. Run ./scripts/list-agents.sh to check status."
