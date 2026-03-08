#!/usr/bin/env bash
# fashion-log.sh — Structured logging for Fashion Radar skill
#
# Usage: fashion-log.sh <event> [key=value ...]
#
# Events:
#   query_start       — New trend query initiated
#   memory_recall     — Pre-scan knowledge lookup result
#   source_scan       — Editorial/social source scanned
#   synthesis         — Trends synthesized from sources
#   memory_store      — Post-scan learning stored
#   scan_complete     — Trend scan pipeline finished
#   heartbeat_refresh — Lightweight trend update during heartbeat
#   error             — Unrecoverable error
#
# Key=value pairs (all optional, use what applies):
#   category=womenswear|menswear|unisex|accessories|footwear|beauty
#   scope=trends|items|colors|silhouettes|materials|brands
#   season=spring-2026|fall-2026|etc
#   occasion=casual|work|evening|wedding|travel|festival
#   source=vogue.com                (editorial source domain)
#   method=web_fetch|browser        (how source was accessed)
#   status=ok|thin|error|empty
#   trends_extracted=5              (count of trends found)
#   trends_reported=3               (count of trends in final response)
#   sources_used=3                  (count of sources scanned)
#   memory_hits=2                   (relevant memory entries found)
#   freshness=fresh|stale|empty     (knowledge freshness)
#   personalized=yes|no             (was response personalized to profile)
#   entries_written=1               (knowledge entries written)
#   note="free text observation"

set -uo pipefail

LOG_DIR="/tmp/openclaw"
LOG_FILE="${LOG_DIR}/fashion-radar.log"

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
