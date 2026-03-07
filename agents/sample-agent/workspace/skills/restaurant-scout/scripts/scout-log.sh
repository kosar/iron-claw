#!/usr/bin/env bash
# scout-log.sh — Structured logging for Restaurant Scout skill
#
# Usage: scout-log.sh <event> [key=value ...]
#
# Events:
#   scout_start        — New scout request initiated
#   memory_recall      — Pre-search knowledge lookup
#   discovery_search   — web_search for restaurant/candidates
#   page_fetch         — web_fetch on restaurant homepage
#   platform_detected  — Reservation platform identified
#   deeplink_built     — Pre-filled booking URL generated
#   memory_store       — Post-scout learning stored
#   scout_complete     — Pipeline finished, response sent
#   error              — Unrecoverable failure
#
# Key=value pairs (use what applies):
#   restaurant="Carbone"
#   city="New York"
#   party=2
#   date=2026-02-21
#   time=19:30
#   platform=resy|opentable|tock|sevenrooms|yelp|direct|call|walk-in
#   slug=carbone
#   memory_hits=1
#   search_results=8
#   status=ok|error|empty|no-platform
#   deeplink="https://resy.com/..."
#   note="free text observation"

set -uo pipefail

LOG_DIR="/tmp/openclaw"
LOG_FILE="${LOG_DIR}/scout.log"

mkdir -p "$LOG_DIR" 2>/dev/null || true

EVENT="${1:-unknown}"
shift 2>/dev/null || true

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

JSON="{\"timestamp\":\"${TIMESTAMP}\",\"event\":\"${EVENT}\""

for ARG in "$@"; do
  KEY="${ARG%%=*}"
  VALUE="${ARG#*=}"
  [ "$KEY" = "$ARG" ] && continue
  VALUE=$(echo "$VALUE" | sed 's/"/\\"/g')
  if echo "$VALUE" | grep -qE '^[0-9]+$'; then
    JSON="${JSON},\"${KEY}\":${VALUE}"
  else
    JSON="${JSON},\"${KEY}\":\"${VALUE}\""
  fi
done

JSON="${JSON}}"

echo "$JSON" >> "$LOG_FILE" 2>/dev/null
echo "$JSON"
