#!/usr/bin/env bash
# probe-agents.sh — List all agents with container status (JSON). For ironclaw dashboard.
# Usage: IRONCLAW_ROOT=/path/to/ironclaw ./probe-agents.sh
# Output: JSON to stdout

set -e
ROOT="${IRONCLAW_ROOT:?IRONCLAW_ROOT required}"
BASE="$ROOT/agents"

# Use python3 for JSON (works without jq)
python3 - "$BASE" << 'PY'
import os
import json
import subprocess

base = os.environ.get("IRONCLAW_ROOT", "") + "/agents"
if not os.path.isdir(base):
    print(json.dumps({"ok": False, "error": "agents dir not found"}))
    exit(0)

agents = []
for name in sorted(os.listdir(base)):
    if name == "template":
        continue
    dirpath = os.path.join(base, name)
    conf = os.path.join(dirpath, "agent.conf")
    if not os.path.isfile(conf):
        continue
    # Parse agent.conf (simple KEY=VALUE)
    port = mem = cpus = container = ""
    with open(conf) as f:
        for line in f:
            line = line.strip()
            if line.startswith("AGENT_PORT="):
                port = line.split("=", 1)[1].strip("'\"").strip()
            elif line.startswith("AGENT_MEM_LIMIT="):
                mem = line.split("=", 1)[1].strip("'\"").strip()
            elif line.startswith("AGENT_CPUS="):
                cpus = line.split("=", 1)[1].strip("'\"").strip()
            elif line.startswith("AGENT_CONTAINER="):
                container = line.split("=", 1)[1].strip("'\"").strip()
    status = "stopped"
    health = ""
    try:
        r = subprocess.run(
            ["docker", "inspect", "--format={{.State.Status}}", container],
            capture_output=True, text=True, timeout=5
        )
        if r.returncode == 0 and r.stdout.strip():
            status = r.stdout.strip()
        r2 = subprocess.run(
            ["docker", "inspect", "--format={{.State.Health.Status}}", container],
            capture_output=True, text=True, timeout=5
        )
        if r2.returncode == 0 and r2.stdout.strip() and r2.stdout.strip() != "<no value>":
            health = r2.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    agents.append({
        "name": name,
        "port": port,
        "mem": mem,
        "cpus": cpus,
        "container": container,
        "status": status,
        "health": health or None,
    })
print(json.dumps({"ok": True, "agents": agents}))
PY
