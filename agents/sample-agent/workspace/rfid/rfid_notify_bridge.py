#!/usr/bin/env python3
"""
RFID notify bridge — runs on the Pi host (e.g. every 10s via systemd timer).
Checks last_scan.json; if newer than last notified, calls the OpenClaw gateway
so the agent is notified even if the daemon's immediate notify failed.
Use as a robust fallback alongside rfid_daemon.py.
"""

import json
import os
import sys
import urllib.request
import urllib.error

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LAST_SCAN = os.path.join(SCRIPT_DIR, "last_scan.json")
LAST_NOTIFIED = os.path.join(SCRIPT_DIR, ".last_notified.json")
PIBOT_ENV = os.path.join(SCRIPT_DIR, "..", "..", ".env")
AGENT_CONF = os.path.join(SCRIPT_DIR, "..", "..", "agent.conf")
CONFIG_JSON = os.path.join(SCRIPT_DIR, "..", "..", "config", "openclaw.json")


def load_env():
    if not os.path.isfile(PIBOT_ENV):
        return
    with open(PIBOT_ENV) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                k, v = k.strip(), v.strip()
                if k and v and k not in os.environ:
                    os.environ[k] = v


def get_agent_port():
    if not os.path.isfile(AGENT_CONF):
        return None
    try:
        with open(AGENT_CONF) as f:
            for line in f:
                line = line.strip()
                if line.startswith("AGENT_PORT="):
                    return line.split("=", 1)[1].strip().strip("'\"")
    except OSError:
        pass
    return None


def get_telegram_chat_id():
    """First Telegram allowFrom user ID from config. For DMs, chat_id is the same as the user ID."""
    if not os.path.isfile(CONFIG_JSON):
        return None
    try:
        with open(CONFIG_JSON) as f:
            cfg = json.load(f)
        allow_from = cfg.get("channels", {}).get("telegram", {}).get("allowFrom", [])
        if allow_from:
            return str(allow_from[0])
    except (json.JSONDecodeError, KeyError):
        pass
    return None


def main():
    load_env()
    hooks_token = os.environ.get("OPENCLAW_HOOKS_TOKEN")
    port = get_agent_port()
    chat_id = get_telegram_chat_id()
    if not hooks_token or not port or not chat_id:
        sys.exit(0)
    if not os.path.isfile(LAST_SCAN):
        sys.exit(0)
    try:
        with open(LAST_SCAN) as f:
            scan = json.load(f)
    except (json.JSONDecodeError, OSError):
        sys.exit(0)
    tag_id = scan.get("tag_id") or scan.get("uid_hex") or "unknown"
    ts = scan.get("timestamp_iso") or ""
    if not ts:
        sys.exit(0)
    last_ts = None
    if os.path.isfile(LAST_NOTIFIED):
        try:
            with open(LAST_NOTIFIED) as f:
                last_ts = json.load(f).get("timestamp_iso")
        except (json.JSONDecodeError, OSError):
            pass
    if last_ts == ts:
        sys.exit(0)
    url = f"http://127.0.0.1:{port}/hooks/agent"
    message = (
        f"RFID scan: {tag_id} at {ts}. (Automated notification — process this event: "
        "run the RFID/dog-tracking flow, then reply with the appropriate acknowledgment to this Telegram chat.)"
    )
    body = json.dumps({
        "message": message,
        "name": "RFID",
        "agentId": "main",
        "wakeMode": "now",
        "deliver": True,
        "channel": "telegram",
        "to": chat_id,
        "timeoutSeconds": 120,
    }).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {hooks_token}",
            "x-openclaw-token": hooks_token,
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            if 200 <= r.status < 300:
                with open(LAST_NOTIFIED, "w") as f:
                    json.dump({"timestamp_iso": ts, "tag_id": tag_id}, f)
    except Exception:
        pass
    sys.exit(0)


if __name__ == "__main__":
    main()
