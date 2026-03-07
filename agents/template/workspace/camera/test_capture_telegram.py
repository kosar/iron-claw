#!/usr/bin/env python3
"""
One-off test: capture one frame from the first USB camera, send it to Telegram.
Run on the Pi host: python3 agents/pibot/workspace/camera/test_capture_telegram.py
"""
import json
import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PIBOT_ENV = os.path.join(SCRIPT_DIR, "..", "..", ".env")
CONFIG_PATH = os.path.join(SCRIPT_DIR, "..", "..", "config", "openclaw.json")
LATEST_PATH = os.path.join(SCRIPT_DIR, "latest.jpg")


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
    if not os.path.isfile(CONFIG_PATH):
        return None
    try:
        with open(CONFIG_PATH) as f:
            cfg = json.load(f)
        allow_from = cfg.get("channels", {}).get("telegram", {}).get("allowFrom", [])
        if allow_from:
            return str(allow_from[0])
    except (json.JSONDecodeError, KeyError):
        pass
    return None


def list_video_devices():
    out = []
    for i in range(8):
        p = f"/dev/video{i}"
        if os.path.exists(p):
            out.append(p)
    return sorted(out)


def main():
    load_env()
    token = os.environ.get("TELEGRAM_BOT_TOKEN")
    chat_id = get_telegram_chat_id()
    if not token or not chat_id:
        print("Need TELEGRAM_BOT_TOKEN in .env and allowFrom in config/openclaw.json", file=sys.stderr)
        sys.exit(1)

    devices = list_video_devices()
    if not devices:
        print("No /dev/video* devices found", file=sys.stderr)
        sys.exit(1)
    device = devices[0]
    os.makedirs(SCRIPT_DIR, exist_ok=True)
    tmp = os.path.join(SCRIPT_DIR, "_capture_tmp.jpg")  # .jpg so image2 muxer accepts it
    brightness = float(os.environ.get("CAMERA_BRIGHTNESS", "0.2"))
    contrast = float(os.environ.get("CAMERA_CONTRAST", "1.08"))
    vf = f"eq=brightness={brightness}:contrast={contrast}"
    cmd = ["ffmpeg", "-y", "-f", "v4l2", "-i", device, "-vf", vf, "-frames:v", "1", "-q:v", "2", "-update", "1", tmp]
    try:
        subprocess.run(cmd, capture_output=True, timeout=15, check=False)
    except Exception as e:
        print(f"Capture failed: {e}", file=sys.stderr)
        sys.exit(1)
    if not os.path.isfile(tmp):
        print("ffmpeg did not produce output", file=sys.stderr)
        sys.exit(1)
    os.replace(tmp, LATEST_PATH)
    print(f"Captured to {LATEST_PATH} from {device}", file=sys.stderr)

    url = f"https://api.telegram.org/bot{token}/sendPhoto"
    r = subprocess.run(
        ["curl", "-sf", "-X", "POST", url, "-F", f"chat_id={chat_id}", "-F", f"photo=@{LATEST_PATH}", "-F", "caption=Test photo from Pi camera"],
        capture_output=True,
        timeout=15,
    )
    if r.returncode != 0:
        print("Telegram send failed", file=sys.stderr)
        sys.exit(1)
    print("Sent test photo to Telegram.")


if __name__ == "__main__":
    main()
