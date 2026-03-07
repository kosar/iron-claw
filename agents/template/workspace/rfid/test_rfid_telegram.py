#!/usr/bin/env python3
"""
One-off test on the Pi: verify RC522 init and read, then send a Telegram message.
Run from repo root: python3 agents/pibot/workspace/rfid/test_rfid_telegram.py
"""
import json
import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PIBOT_ENV = os.path.join(SCRIPT_DIR, "..", "..", ".env")


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


def get_telegram_chat_id():
    config_path = os.path.join(SCRIPT_DIR, "..", "..", "config", "openclaw.json")
    if not os.path.isfile(config_path):
        return None
    try:
        with open(config_path) as f:
            cfg = json.load(f)
        allow_from = cfg.get("channels", {}).get("telegram", {}).get("allowFrom", [])
        if allow_from:
            return str(allow_from[0])
    except (json.JSONDecodeError, KeyError):
        pass
    return None


def send_telegram(token: str, chat_id: str, text: str) -> bool:
    try:
        r = subprocess.run(
            [
                "curl", "-sf", "-X", "POST",
                f"https://api.telegram.org/bot{token}/sendMessage",
                "-d", f"chat_id={chat_id}",
                "--data-urlencode", f"text={text}",
            ],
            capture_output=True,
            timeout=10,
        )
        return r.returncode == 0
    except Exception:
        return False


def main():
    load_env()
    token = os.environ.get("TELEGRAM_BOT_TOKEN")
    chat_id = get_telegram_chat_id()

    # 1) RFID
    rfid_ok = False
    tag_seen = None
    try:
        import RPi.GPIO as GPIO
        from mfrc522 import SimpleMFRC522
        reader = SimpleMFRC522()
        for _ in range(5):
            try:
                id_val, text = reader.read_no_block()
                if id_val is not None:
                    tag_seen = (text.strip() if text and text.strip() else format(id_val, "x"))
                    break
            except Exception:
                pass
            import time
            time.sleep(0.3)
        GPIO.cleanup()
        rfid_ok = True
    except ImportError as e:
        print(f"RFID import error: {e}", file=sys.stderr)
        print("Install: pip install mfrc522 RPi.GPIO  (and enable SPI: raspi-config)", file=sys.stderr)
    except Exception as e:
        print(f"RFID error: {e}", file=sys.stderr)

    rfid_msg = "reader OK, no tag" if rfid_ok and not tag_seen else ("reader OK, tag: " + tag_seen if tag_seen else "reader init failed")

    # 2) Telegram
    if not token:
        print("TELEGRAM_BOT_TOKEN missing in .env", file=sys.stderr)
        sys.exit(1)
    if not chat_id:
        print("channels.telegram.allowFrom missing in config/openclaw.json", file=sys.stderr)
        sys.exit(1)
    msg = f"RFID test from Pi: {rfid_msg}"
    if send_telegram(token, chat_id, msg):
        print("Telegram sent:", msg)
    else:
        print("Telegram send failed", file=sys.stderr)
        sys.exit(1)
    print("RFID:", rfid_msg)


if __name__ == "__main__":
    main()
