#!/usr/bin/env bash
# trend-scan.sh — Lightweight URL fetcher for editorial fashion sites
#
# Usage: trend-scan.sh <url> [timeout_seconds]
#
# Fetches the given URL and outputs the body content.
# Used as a fallback when web_fetch tool is unavailable or for
# scripted batch scanning during heartbeat cycles.
#
# Returns: page content on stdout, exit code 0 on success
# On failure: error message on stderr, exit code 1

set -uo pipefail

URL="${1:?Usage: trend-scan.sh <url> [timeout_seconds]}"
TIMEOUT="${2:-30}"

# Validate URL (basic SSRF protection)
if echo "$URL" | grep -qE '(localhost|127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|host\.docker\.internal|metadata\.google)'; then
  echo "Error: blocked URL (internal/private address)" >&2
  exit 1
fi

# Fetch with curl
RESPONSE=$(curl -sS -L \
  --max-time "$TIMEOUT" \
  --max-redirs 5 \
  -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
  -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
  -H "Accept-Language: en-US,en;q=0.9" \
  "$URL" 2>&1)

EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
  echo "Error: curl failed with exit code $EXIT_CODE" >&2
  echo "$RESPONSE" >&2
  exit 1
fi

# Output the response
echo "$RESPONSE"
