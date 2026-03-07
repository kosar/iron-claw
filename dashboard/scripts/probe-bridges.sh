#!/usr/bin/env bash
# probe-bridges.sh — Check host bridge ports 18792, 18793, 18794 (JSON). For ironclaw dashboard.
# Usage: ./probe-bridges.sh
# Output: JSON to stdout

set -e
# Port -> name, health path
# 18792: capture service (POST /capture or GET health if exists)
# 18793: PiGlow GET /signal or /health
# 18794: PiFace display

python3 - << 'PY'
import json
import socket
import urllib.request
import urllib.error

def port_listening(port):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1)
        s.connect(("127.0.0.1", port))
        s.close()
        return True
    except (socket.error, OSError):
        return False

def http_ok(url, timeout=2):
    try:
        req = urllib.request.Request(url)
        urllib.request.urlopen(req, timeout=timeout)
        return True
    except Exception:
        return False

# capture (18792): no safe health endpoint - /capture triggers photo; only check listening
# piglow (18793): GET /health
# piface (18794): check listening; optional GET if it has a safe path
bridges = [
    {"name": "capture", "port": 18792, "path": None},
    {"name": "piglow", "port": 18793, "path": "/health"},
    {"name": "piface", "port": 18794, "path": "/display"},
]
out = []
for b in bridges:
    port = b["port"]
    listening = port_listening(port)
    reachable = False
    detail = ""
    if listening and b["path"]:
        url = "http://127.0.0.1:{}{}".format(port, b["path"])
        try:
            req = urllib.request.Request(url)
            if b["path"] == "/display":
                req.get_method = lambda: "GET"
            r = urllib.request.urlopen(req, timeout=2)
            reachable = r.status == 200
            detail = "ok"
        except urllib.error.HTTPError as e:
            detail = "HTTP {}".format(e.code)
        except Exception as e:
            detail = str(e)[:80]
    elif listening and not b["path"]:
        reachable = True
        detail = "listening (no health endpoint)"
    out.append({
        "name": b["name"],
        "port": port,
        "listening": listening,
        "reachable": reachable,
        "detail": detail or ("ok" if reachable else "not reachable"),
    })
print(json.dumps({"ok": True, "bridges": out}))
PY
