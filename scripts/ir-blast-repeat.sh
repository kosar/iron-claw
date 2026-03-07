#!/usr/bin/env bash
# Blast a learned IR file over and over with a quiet gap between each send.
# Usage: ./scripts/ir-blast-repeat.sh <file.ir> [gap_seconds]
# Example: ./scripts/ir-blast-repeat.sh agents/pibot/workspace/ir-codes/fanremote2/power.ir 3
# Ctrl+C to stop.
set -e
FILE="${1:?Usage: $0 <path/to/file.ir> [gap_seconds]}"
GAP="${2:-3}"
if [[ ! -f "$FILE" ]]; then
  echo "Not found: $FILE" >&2
  exit 1
fi
echo "Blasting every ${GAP}s: $FILE  (Ctrl+C to stop)"
n=0
while true; do
  n=$((n+1))
  ./scripts/ir-blast.sh "$FILE" 2>/dev/null || true
  echo "  [$n] sent"
  sleep "$GAP"
done
