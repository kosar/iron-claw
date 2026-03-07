#!/usr/bin/env python3
"""
RFID scan watcher — generic. Reads last_scan.json (written by the daemon), optional
card_names.json (tag_id/uid_hex → display name and options), and prints one line for
the bot to send (e.g. dog-tracking or generic). No instance-specific data in this file.
"""
import json
import os
import sys
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# When run in container, workspace/rfid is mounted; when run on host for testing, use script dir
if os.path.exists("/home/ai_sandbox/.openclaw/workspace/rfid/last_scan.json"):
    RFID_DIR = "/home/ai_sandbox/.openclaw/workspace/rfid"
else:
    RFID_DIR = SCRIPT_DIR

LAST_SCAN_FILE = os.path.join(RFID_DIR, "last_scan.json")
STATE_FILE = os.path.join(RFID_DIR, ".watcher_state.json")
CARD_NAMES_FILE = os.path.join(RFID_DIR, "card_names.json")

RESERVED_KEYS = ("_timezone", "_dog_tracking_names", "_dog_tracking_message", "_card_sounds")


def load_card_config():
    """Load card_names.json. Returns (config_dict, card_names_dict). Config has _* keys; card_names has tag_id/uid_hex → display name."""
    config = {}
    card_names = {}
    if not os.path.isfile(CARD_NAMES_FILE):
        return config, card_names
    try:
        with open(CARD_NAMES_FILE, "r") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return config, card_names
        for k in list(data):
            if k in RESERVED_KEYS:
                config[k] = data.pop(k)
            else:
                card_names[k] = data[k]
        return config, card_names
    except (json.JSONDecodeError, OSError):
        return {}, {}


def load_state():
    """Load last known scan state. Creates empty state file if missing."""
    if not os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "w") as f:
                json.dump({}, f)
        except OSError:
            pass
        return None
    try:
        with open(STATE_FILE, "r") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return None


def save_state(scan_data):
    """Save current scan state (atomic write)."""
    tmp = STATE_FILE + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(scan_data, f)
        os.replace(tmp, STATE_FILE)
    except OSError:
        pass


def _normalize_tag(tag_id):
    """Normalize for lookup: lowercase, spaces to underscores."""
    if not tag_id or not isinstance(tag_id, str):
        return tag_id
    return tag_id.strip().lower().replace(" ", "_")


def get_card_name(tag_id, uid_hex, card_names):
    """Resolve tag_id/uid_hex to display name using card_names dict."""
    if not card_names:
        return f"Card {tag_id or uid_hex}"
    normalized = _normalize_tag(tag_id) if tag_id else None
    name = (
        card_names.get(tag_id)
        or card_names.get(normalized)
        or card_names.get(uid_hex)
    )
    if name:
        return name
    return f"Card {tag_id or uid_hex}"


def format_time_pst(timestamp, tz_name):
    """Format ISO timestamp in the given timezone (e.g. America/Los_Angeles)."""
    try:
        dt_utc = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        if dt_utc.tzinfo is None:
            dt_utc = dt_utc.replace(tzinfo=timezone.utc)
        if tz_name:
            try:
                from zoneinfo import ZoneInfo
                dt_local = dt_utc.astimezone(ZoneInfo(tz_name))
                return dt_local.strftime("%I:%M %p %Z")
            except Exception:
                pass
        return dt_utc.strftime("%I:%M %p UTC")
    except Exception:
        return timestamp


def main():
    if not os.path.exists(LAST_SCAN_FILE):
        sys.exit(0)

    config, card_names = load_card_config()
    tz_name = config.get("_timezone") or ""
    dog_names = config.get("_dog_tracking_names")
    if not isinstance(dog_names, list):
        dog_names = []
    dog_message = config.get("_dog_tracking_message") or "🐾 {card_name} scanned at {time}"

    with open(LAST_SCAN_FILE, "r") as f:
        current = json.load(f)

    previous = load_state()
    if previous and current.get("timestamp_iso") == previous.get("timestamp_iso"):
        sys.exit(0)

    save_state(current)

    tag_id = current.get("tag_id", "unknown")
    uid_hex = current.get("uid_hex", "unknown")
    timestamp = current.get("timestamp_iso", "unknown")
    card_name = get_card_name(tag_id, uid_hex, card_names)
    time_str = format_time_pst(timestamp, tz_name)

    if dog_names and card_name in dog_names and dog_message:
        print(dog_message.format(card_name=card_name, time=time_str))
    else:
        print(f"📛 {card_name} scanned at {time_str}")

    sys.exit(0)


if __name__ == "__main__":
    main()
