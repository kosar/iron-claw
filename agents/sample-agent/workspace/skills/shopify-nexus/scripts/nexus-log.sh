#!/usr/bin/env bash
# nexus-log.sh — Structured logging for Shopify Nexus skill
#
# Usage: nexus-log.sh <event> [key=value ...]
#
# Events:
#   search_start        — New search initiated
#   domain_validation    — SSRF check result
#   domain_correction    — Self-healing domain fix attempted
#   memory_recall        — Pre-search memory lookup result
#   mcp_discovery        — MCP endpoint capability probe
#   mcp_search           — MCP product search executed
#   products_json_search — Legacy products.json fallback
#   search_fallback      — Switching from MCP to fallback
#   results_summary      — Post-search result evaluation
#   genius_call          — Chatsi Genius API call
#   memory_store         — Post-search learning stored
#   search_complete      — Search pipeline finished
#   error                — Unrecoverable error
#
# Key=value pairs (all optional, use what applies):
#   domain=allbirds.com
#   query="running shoes"
#   mode=catalog|policy
#   endpoint=mcp|products_json
#   status=ok|error|empty|timeout|404|invalid
#   products=5                    (count of products returned)
#   payload_bytes=12340           (response payload size)
#   request_bytes=256             (request payload size)
#   mcp_tools="search_products,get_collections"  (discovered MCP tools)
#   mcp_resources="products,collections,policies" (discovered MCP resources)
#   correction_from=allbird.com   (original bad domain)
#   correction_to=allbirds.com    (corrected domain)
#   correction_method=myshopify|www|spelling
#   relevance=high|medium|low
#   detail=rich|partial|sparse
#   duration_ms=1234
#   reason="connection refused"   (error details)
#   query_level=1|2|3             (query sophistication level)
#   memory_hits=2                 (number of relevant memory entries found)
#   fallback_reason="MCP returned 404"
#   genius_status=ok|offline
#   note="free text observation"

set -uo pipefail

LOG_DIR="/tmp/openclaw"
LOG_FILE="${LOG_DIR}/nexus-search.log"

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

  # Detect numeric values (integers only — don't break decimals or strings)
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
