#!/usr/bin/env bash
# smoke-test.sh — Create a temporary agent, start it, test gateway HTTP, teardown.
# Usage: ./scripts/smoke-test.sh
# Use in CI or locally to verify the template and compose-up path work.
# Requires: Docker, jq, and the ironclaw image (docker build -t ironclaw:2.0 .).

set -e
BASE="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_NAME="smoke-test-agent"
AGENT_DIR="$BASE/agents/$AGENT_NAME"

cleanup() {
  echo "[smoke-test] Teardown..."
  docker compose -p "$AGENT_NAME" down --volumes 2>/dev/null || true
  rm -rf "$AGENT_DIR"
}

trap cleanup EXIT

echo "[smoke-test] Creating temporary agent $AGENT_NAME..."
"$BASE/scripts/create-agent.sh" "$AGENT_NAME" 2>/dev/null || { echo "create-agent.sh failed"; exit 1; }

echo "[smoke-test] Setting minimal .env..."
TOKEN=$(openssl rand -hex 24 2>/dev/null || echo "test-token-please-set-OPENCLAW_GATEWAY_TOKEN")
echo "OPENCLAW_GATEWAY_TOKEN=$TOKEN" > "$AGENT_DIR/.env"
echo "OPENCLAW_OWNER_DISPLAY_SECRET=smoke-test-secret" >> "$AGENT_DIR/.env"

echo "[smoke-test] Starting agent..."
"$BASE/scripts/compose-up.sh" "$AGENT_NAME" -d 2>/dev/null || { echo "compose-up.sh failed"; exit 1; }

echo "[smoke-test] Waiting for gateway to be up..."
for i in 1 2 3 4 5 6 7 8 9 10; do
  if "$BASE/scripts/test-gateway-http.sh" "$AGENT_NAME" >/dev/null 2>&1; then
    echo "[smoke-test] Gateway responded OK."
    exit 0
  fi
  sleep 2
done

echo "[smoke-test] Gateway did not respond in time."
exit 1
