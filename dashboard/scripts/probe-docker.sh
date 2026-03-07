#!/usr/bin/env bash
# probe-docker.sh — List ironclaw containers (JSON). For ironclaw dashboard.
# Usage: IRONCLAW_ROOT=/path ./probe-docker.sh
# Output: JSON to stdout

set -e
python3 - << 'PY'
import json
import subprocess

try:
    r = subprocess.run(
        ["docker", "ps", "-a", "--format", "{{.Names}}\t{{.Status}}\t{{.CreatedAt}}"],
        capture_output=True, text=True, timeout=10
    )
except FileNotFoundError:
    print(json.dumps({"ok": True, "containers": []}))
    exit(0)
if r.returncode != 0:
    print(json.dumps({"ok": False, "error": "docker failed", "containers": []}))
    exit(0)

containers = []
for line in (r.stdout or "").strip().splitlines():
    parts = line.split("\t", 2)
    if len(parts) < 2:
        continue
    name = parts[0]
    # Only ironclaw *_secure containers
    if not name.endswith("_secure"):
        continue
    status = parts[1]
    created = parts[2] if len(parts) > 2 else ""
    # Simplify status: "Up 2 hours (healthy)" -> "running (healthy)"
    containers.append({
        "name": name,
        "status": status,
        "created": created,
    })
print(json.dumps({"ok": True, "containers": containers}))
PY
