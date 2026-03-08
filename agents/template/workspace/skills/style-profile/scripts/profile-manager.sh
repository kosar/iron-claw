#!/usr/bin/env bash
# profile-manager.sh — Read-only convenience operations for style profiles
#
# Usage:
#   profile-manager.sh read <identifier>   — Show a specific customer's profile
#   profile-manager.sh list                — List all customer identifiers
#   profile-manager.sh search <keyword>    — Search profiles for a keyword
#
# The profiles file is the single source of truth:
#   /home/openclaw/.openclaw/workspace/skills/style-profile/customer-profiles.md

set -uo pipefail

PROFILES="/home/openclaw/.openclaw/workspace/skills/style-profile/customer-profiles.md"
COMMAND="${1:?Usage: profile-manager.sh <read|list|search> [arg]}"

if [ ! -f "$PROFILES" ]; then
  echo "No profiles file found. No customers yet."
  exit 0
fi

case "$COMMAND" in
  read)
    IDENTIFIER="${2:?Usage: profile-manager.sh read <identifier>}"
    # Extract the section for this customer (from ## [customer:X] to the next ## or EOF)
    awk -v id="$IDENTIFIER" '
      /^## \[customer:/ {
        if (found) exit
        if (index($0, "[customer:" id "]") > 0) found=1
      }
      found { print }
    ' "$PROFILES"
    if [ $? -ne 0 ] || [ -z "$(awk -v id="$IDENTIFIER" '/^## \[customer:/ { if (index($0, "[customer:" id "]") > 0) { print "found"; exit } }' "$PROFILES")" ]; then
      echo "No profile found for: $IDENTIFIER"
      exit 0
    fi
    ;;

  list)
    # Extract all customer identifiers
    grep -oP '(?<=\[customer:)[^\]]+' "$PROFILES" 2>/dev/null || echo "No customers found."
    ;;

  search)
    KEYWORD="${2:?Usage: profile-manager.sh search <keyword>}"
    # Search for keyword across all profiles, showing matching lines with context
    grep -i -n "$KEYWORD" "$PROFILES" 2>/dev/null || echo "No matches for: $KEYWORD"
    ;;

  *)
    echo "Unknown command: $COMMAND"
    echo "Usage: profile-manager.sh <read|list|search> [arg]"
    exit 1
    ;;
esac
