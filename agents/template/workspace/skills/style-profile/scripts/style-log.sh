#!/usr/bin/env bash
# style-log.sh — Structured logging for Style Profile skill
#
# Usage: style-log.sh <event> [key=value ...]
#
# Events:
#   profile_read      — Customer profile loaded
#   profile_write     — Customer profile created or updated
#   profile_not_found — Looked up a customer with no profile
#   history_append    — Interaction added to customer history
#   profile_list      — Listed all profiles
#   profile_search    — Searched profiles for keyword
#   error             — Unrecoverable error
#
# Key=value pairs (all optional, use what applies):
#   customer=@janedoe             (customer identifier)
#   status=found|not_found|created|updated
#   fields_updated="sizes,colors" (comma-separated field names)
#   note="free text observation"

set -uo pipefail

LOG_DIR="/tmp/openclaw"
LOG_FILE="${LOG_DIR}/style-profile.log"

# Ensure log directory exists
mkdir -p "$LOG_DIR" 2>/dev/null || true

EVENT="${1:-unknown}"
shift 2>/dev/null || true

# Build JSON object from key=value args
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

# Start JSON
JSON="{\"timestamp\":\"${TIMESTAMP}\",\"event\":\"${EVENT}\""

# Parse key=value pairs
for ARG in "$@"; do
  KEY="${ARG%%=*}"
  VALUE="${ARG#*=}"

  # Skip malformed args
  [ "$KEY" = "$ARG" ] && continue

  # Escape quotes in value
  VALUE=$(echo "$VALUE" | sed 's/"/\\"/g')

  # Detect numeric values (integers only)
  if echo "$VALUE" | grep -qE '^[0-9]+$'; then
    JSON="${JSON},\"${KEY}\":${VALUE}"
  else
    JSON="${JSON},\"${KEY}\":\"${VALUE}\""
  fi
done

JSON="${JSON}}"

# Append to log file
echo "$JSON" >> "$LOG_FILE" 2>/dev/null

# Also echo to stdout so the agent sees confirmation
echo "$JSON"
