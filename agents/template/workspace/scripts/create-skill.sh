#!/usr/bin/env bash
# create-skill.sh — Wrapper around OpenClaw's skill-creator init_skill.py
# Automatically resolves the correct workspace skills directory.
#
# Usage:
#   bash create-skill.sh <skill-name> [--resources scripts,references,assets] [--examples]
#
# Examples:
#   bash create-skill.sh my-skill
#   bash create-skill.sh my-skill --resources scripts
#   bash create-skill.sh my-skill --resources scripts,references --examples

set -euo pipefail

SKILL_NAME="${1:?Usage: create-skill.sh <skill-name> [--resources ...] [--examples]}"
shift

# Resolve paths
WORKSPACE_SKILLS="$HOME/.openclaw/workspace/skills"
INIT_SCRIPT="$(find "$HOME" -path '*/skills/skill-creator/scripts/init_skill.py' -type f 2>/dev/null | head -1)"

if [[ -z "$INIT_SCRIPT" ]]; then
  echo "ERROR: init_skill.py not found. Is OpenClaw installed?" >&2
  exit 1
fi

if [[ -d "$WORKSPACE_SKILLS/$SKILL_NAME" ]]; then
  echo "ERROR: Skill '$SKILL_NAME' already exists at $WORKSPACE_SKILLS/$SKILL_NAME" >&2
  exit 1
fi

mkdir -p "$WORKSPACE_SKILLS"
exec python3 "$INIT_SCRIPT" "$SKILL_NAME" --path "$WORKSPACE_SKILLS" "$@"
