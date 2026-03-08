#!/usr/bin/env bash
# chatsi-genius.sh — Chatsi Product Genius API caller
# Usage: chatsi-genius.sh '<base64-encoded-json-payload>'
# Outputs JSON to stdout, exits 0 on success, 1 on failure.

set -euo pipefail

PAYLOAD_B64="${1:-}"

if [ -z "$PAYLOAD_B64" ]; then
  echo '{"error":"genius_offline","reason":"no payload provided"}'
  exit 1
fi

# Decode payload
PAYLOAD=$(echo "$PAYLOAD_B64" | base64 -d 2>/dev/null) || {
  echo '{"error":"genius_offline","reason":"invalid base64 payload"}'
  exit 1
}

# Required env vars
API_URL="${CHATSI_API_URL:-}"
MERCHANT_ID="${CHATSI_MERCHANT_ID:-}"

if [ -z "$API_URL" ] || [ -z "$MERCHANT_ID" ]; then
  echo '{"error":"genius_offline","reason":"CHATSI_API_URL or CHATSI_MERCHANT_ID not configured"}'
  exit 1
fi

ENDPOINT="${API_URL}/genius/chat?merchantId=${MERCHANT_ID}"

# Determine auth method: OAuth2 takes precedence over API key
TOKEN_URL="${CHATSI_ACCESS_TOKEN_URL:-}"
CLIENT_ID="${CHATSI_API_CLIENT_ID:-}"
CLIENT_SECRET="${CHATSI_API_CLIENT_SECRET:-}"
CLIENT_SCOPE="${CHATSI_API_CLIENT_SCOPE:-}"

API_KEY="${CHATSI_API_KEY:-}"
SUBSCRIPTION_KEY="${CHATSI_SUBSCRIPTION_KEY:-}"

AUTH_HEADER=""

if [ -n "$TOKEN_URL" ] && [ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ]; then
  # OAuth2 client_credentials flow
  TOKEN_RESPONSE=$(curl -s --max-time 15 -X POST "$TOKEN_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&scope=${CLIENT_SCOPE}" \
    2>/dev/null) || {
    echo '{"error":"genius_offline","reason":"OAuth2 token request failed"}'
    exit 1
  }

  ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -z "$ACCESS_TOKEN" ]; then
    echo '{"error":"genius_offline","reason":"OAuth2 token response missing access_token"}'
    exit 1
  fi

  AUTH_HEADER="Authorization: Bearer ${ACCESS_TOKEN}"

elif [ -n "$API_KEY" ]; then
  # API key auth
  AUTH_HEADER="ApiKey: ${API_KEY}"
else
  echo '{"error":"genius_offline","reason":"no auth credentials configured (need OAuth2 or API key)"}'
  exit 1
fi

# Build curl args
CURL_ARGS=(-s --max-time 30 -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "$AUTH_HEADER" \
  -d "$PAYLOAD")

# Add subscription key header if present (used with API key auth)
if [ -n "$SUBSCRIPTION_KEY" ]; then
  CURL_ARGS+=(-H "Ocp-Apim-Subscription-Key: ${SUBSCRIPTION_KEY}")
fi

# Make the API call
RESPONSE=$(curl "${CURL_ARGS[@]}" 2>/dev/null) || {
  echo '{"error":"genius_offline","reason":"API request failed or timed out"}'
  exit 1
}

# Validate we got JSON back
if ! echo "$RESPONSE" | head -c1 | grep -q '[{[]'; then
  echo '{"error":"genius_offline","reason":"non-JSON response from API"}'
  exit 1
fi

echo "$RESPONSE"
exit 0
