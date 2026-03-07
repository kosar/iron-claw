#!/usr/bin/env bash
# Start the ironclaw host dashboard (web server on port 18795).
# Usage: ./scripts/start-dashboard.sh
# Optional: IRONCLAW_DASHBOARD_PORT=18800 ./scripts/start-dashboard.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IRONCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export IRONCLAW_ROOT
export IRONCLAW_DASHBOARD_PORT="${IRONCLAW_DASHBOARD_PORT:-18795}"

exec python3 "$IRONCLAW_ROOT/dashboard/server.py"
