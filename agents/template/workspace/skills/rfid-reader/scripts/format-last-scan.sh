#!/usr/bin/env bash
# Print a one-line summary of the last RFID scan from workspace/rfid/last_scan.json.
# Uses python3 for JSON (jq is not available in the container). Exit 1 if file missing/invalid.
set -euo pipefail
FILE="${1:-/home/openclaw/.openclaw/workspace/rfid/last_scan.json}"
if [[ ! -f "$FILE" ]]; then
  exit 1
fi
python3 - "$FILE" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        d = json.load(f)
    tag_id = d.get("tag_id", "")
    ts = d.get("timestamp_iso", "")
    if tag_id or ts:
        print(f"Last scan: {tag_id} at {ts}")
    else:
        sys.exit(1)
except (json.JSONDecodeError, KeyError):
    sys.exit(1)
PY
