#!/usr/bin/env bash
# doctor.sh — Preflight check for running IronClaw agents.
# Usage: ./scripts/doctor.sh
# Exits 0 if all required checks pass; non-zero and prints hints otherwise.

set -e
BASE="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

check() {
  if eval "$@"; then
    echo "  OK: $*"
    return 0
  else
    echo "  FAIL: $*"
    ((FAIL++)) || true
    return 1
  fi
}

warn() {
  echo "  WARN: $1"
}

echo "Checking prerequisites..."
check command -v docker
check command -v jq

if docker info >/dev/null 2>&1; then
  echo "  OK: Docker daemon reachable"
else
  echo "  FAIL: Docker daemon not reachable (start Docker and try again)"
  ((FAIL++)) || true
fi

echo ""
echo "Checking repo layout..."
check "[[ -d $BASE/agents/template ]]"
check "[[ -f $BASE/agents/template/config/openclaw.json ]]"
check "[[ -f $BASE/scripts/compose-up.sh ]]"
check "[[ -f $BASE/scripts/lib.sh ]]"

echo ""
echo "Checking for at least one runnable agent..."
FOUND=""
for dir in "$BASE"/agents/*/; do
  name=$(basename "$dir")
  [[ "$name" == "template" ]] && continue
  [[ -f "$dir/agent.conf" ]] || continue
  FOUND=1
  if [[ ! -f "$dir/.env" ]]; then
    warn "agents/$name/.env missing — copy from .env.example and set secrets"
  else
    echo "  OK: agents/$name has .env"
  fi
  if [[ -f "$dir/config/openclaw.json" ]]; then
    if jq empty "$dir/config/openclaw.json" 2>/dev/null; then
      echo "  OK: agents/$name/config/openclaw.json is valid JSON"
    else
      echo "  FAIL: agents/$name/config/openclaw.json invalid JSON"
      ((FAIL++)) || true
    fi
  fi
  break
done
if [[ -z "$FOUND" ]]; then
  echo "  FAIL: No agent with agent.conf found (run ./scripts/create-agent.sh <name>)"
  ((FAIL++)) || true
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "All checks passed. You can run ./scripts/compose-up.sh <agent-name> -d"
  exit 0
else
  echo "Some checks failed. Fix the issues above and run doctor.sh again."
  exit 1
fi
