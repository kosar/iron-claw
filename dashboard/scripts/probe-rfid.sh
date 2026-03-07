#!/usr/bin/env bash
# probe-rfid.sh — RFID daemon and last-scan status (JSON). For dashboard check-in.
# Usage: IRONCLAW_ROOT=/path AGENT_NAME=pibot ./probe-rfid.sh

set -e
ROOT="${IRONCLAW_ROOT:?IRONCLAW_ROOT required}"
AGENT="${AGENT_NAME:-pibot}"
RFID_DIR="$ROOT/agents/$AGENT/workspace/rfid"
LAST_SCAN="$RFID_DIR/last_scan.json"

python3 - "$RFID_DIR" "$LAST_SCAN" "$AGENT" << 'PY'
import json
import os
import subprocess
import sys

rfid_dir = sys.argv[1]
last_scan_path = sys.argv[2]
agent = sys.argv[3]

out = {"ok": True, "agent": agent, "daemonRunning": False, "lastScan": None, "error": None}

# Is the RFID daemon process running? (rfid_daemon.py on the host)
try:
    r = subprocess.run(
        ["pgrep", "-f", "rfid_daemon.py"],
        capture_output=True, text=True, timeout=2
    )
    out["daemonRunning"] = bool(r.returncode == 0 and r.stdout.strip())
except (subprocess.TimeoutExpired, FileNotFoundError):
    pass

if not os.path.isfile(last_scan_path):
    out["lastScan"] = None
    if not out["daemonRunning"]:
        out["error"] = "no daemon and no last_scan.json"
    print(json.dumps(out))
    sys.exit(0)

try:
    with open(last_scan_path) as f:
        scan = json.load(f)
    out["lastScan"] = {
        "tag_id": scan.get("tag_id"),
        "uid_hex": scan.get("uid_hex"),
        "timestamp_iso": scan.get("timestamp_iso"),
    }
except (json.JSONDecodeError, OSError) as e:
    out["lastScan"] = None
    out["error"] = "read failed"
print(json.dumps(out))
PY
