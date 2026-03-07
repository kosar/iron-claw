#!/usr/bin/env python3
"""
RC522 RFID daemon for pibot. Runs on the Raspberry Pi host (not in Docker).
Polls the reader via SPI; on each new scan writes last_scan.json, sends a Telegram message,
notifies the OpenClaw gateway via /hooks/agent, and plays a two-tone latch sound (only after
the scan is persisted and Telegram is sent).
Requires: SPI enabled, mfrc522, RPi.GPIO. TELEGRAM_BOT_TOKEN and OPENCLAW_HOOKS_TOKEN in agents/pibot/.env (must differ from OPENCLAW_GATEWAY_TOKEN); chat ID from config.
Optional: alsa-utils (aplay) for scan sound; daemon generates scan_sound.wav if missing.
"""

import json
import math
import os
import struct
import subprocess
import sys
import time
import urllib.request
import urllib.error
import wave

# Resolve script directory and optional .env (agents/pibot/.env when run from repo)
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PIBOT_ENV = os.path.join(SCRIPT_DIR, "..", "..", ".env")
AGENT_CONF = os.path.join(SCRIPT_DIR, "..", "..", "agent.conf")
RFID_LOG = os.path.join(SCRIPT_DIR, "daemon.log")
SCAN_SOUND_WAV = os.path.join(SCRIPT_DIR, "scan_sound.wav")
CARD_NAMES_FILE = os.path.join(SCRIPT_DIR, "card_names.json")
# ALSA device for 3.5mm jack on Pi (card 2 = bcm2835 Headphones)
ALSA_DEVICE = "plughw:2,0"


def load_env():
    """Load KEY=value from agents/pibot/.env into os.environ if file exists."""
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
    """First Telegram allowFrom user ID from agents/pibot/config/openclaw.json.
    For DMs, chat_id is the same as the user ID."""
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


def get_agent_port():
    """Read AGENT_PORT from agents/pibot/agent.conf."""
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


def log_err(msg: str) -> None:
    """Append one line to daemon.log for debugging (failures only)."""
    try:
        with open(RFID_LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + msg + "\n")
    except OSError:
        pass


def log_msg(msg: str) -> None:
    """Append one line to daemon.log (info)."""
    try:
        with open(RFID_LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + msg + "\n")
    except OSError:
        pass


def audio_bridge_reachable(timeout_s: float = 1.0) -> bool:
    """Return True if the audio bridge /health responds within timeout_s (default 1s for fast scan path)."""
    url = os.environ.get("AUDIO_BRIDGE_URL", "http://127.0.0.1:18796").rstrip("/")
    try:
        req = urllib.request.Request(url + "/health", method="GET")
        with urllib.request.urlopen(req, timeout=timeout_s) as r:
            if r.status == 200:
                return True
    except Exception:
        pass
    return False


def _ramp(n: int, total: int) -> float:
    """Linear ramp for envelope (fade in/out)."""
    if n <= 0 or total <= 0:
        return 1.0
    return min(1.0, n / total)


def ensure_scan_sound_wav() -> None:
    """Create scan_sound.wav (two-tone latch: low then high) if missing. Uses stdlib wave only."""
    if os.path.isfile(SCAN_SOUND_WAV):
        return
    try:
        sample_rate = 22050
        amp = 0.8
        freq1, dur1 = 380, 0.12
        gap_dur = 0.04
        freq2, dur2 = 760, 0.12
        fade = int(0.008 * sample_rate)
        n1 = int(sample_rate * dur1)
        n_gap = int(sample_rate * gap_dur)
        n2 = int(sample_rate * dur2)
        with wave.open(SCAN_SOUND_WAV, "w") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(sample_rate)
            for i in range(n1):
                env = _ramp(i, fade) * _ramp(n1 - i, fade)
                v = int(32767 * amp * env * math.sin(2 * math.pi * freq1 * i / sample_rate))
                w.writeframes(struct.pack("<h", v))
            for _ in range(n_gap):
                w.writeframes(struct.pack("<h", 0))
            for i in range(n2):
                env = _ramp(i, fade) * _ramp(n2 - i, fade)
                v = int(32767 * amp * env * math.sin(2 * math.pi * freq2 * i / sample_rate))
                w.writeframes(struct.pack("<h", v))
    except OSError:
        pass


def ensure_woof_wav() -> None:
    """Create woof.wav (short small-dog woof) if missing. Used for Lucy Love Card."""
    woof_path = os.path.join(SCRIPT_DIR, "woof.wav")
    if os.path.isfile(woof_path):
        return
    try:
        sample_rate = 22050
        amp = 0.75
        b1_freq, b1_dur = 280, 0.09
        gap_dur = 0.025
        b2_freq, b2_dur = 380, 0.07
        fade = int(0.006 * sample_rate)
        n1 = int(sample_rate * b1_dur)
        n_gap = int(sample_rate * gap_dur)
        n2 = int(sample_rate * b2_dur)
        with wave.open(woof_path, "w") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(sample_rate)
            for i in range(n1):
                env = _ramp(i, fade) * _ramp(n1 - i, fade)
                v = int(32767 * amp * env * math.sin(2 * math.pi * b1_freq * i / sample_rate))
                w.writeframes(struct.pack("<h", v))
            for _ in range(n_gap):
                w.writeframes(struct.pack("<h", 0))
            for i in range(n2):
                env = _ramp(i, fade) * _ramp(n2 - i, fade)
                v = int(32767 * amp * env * math.sin(2 * math.pi * b2_freq * i / sample_rate))
                w.writeframes(struct.pack("<h", v))
    except OSError:
        pass


def _normalize_tag(tag_id: str) -> str:
    """Normalize for card lookup: lowercase, spaces to underscores."""
    if not tag_id:
        return tag_id
    return tag_id.strip().lower().replace(" ", "_")


def _get_display_name_and_sound(tag_id: str, uid_hex: str) -> tuple:
    """Load card_names.json and return (display_name, sound_filename or None).
    sound_filename is from _card_sounds[display_name]; only returned if file exists in SCRIPT_DIR."""
    display_name = None
    sound_file = None
    if not os.path.isfile(CARD_NAMES_FILE):
        return display_name, sound_file
    try:
        with open(CARD_NAMES_FILE) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return display_name, sound_file
        card_sounds = data.get("_card_sounds") or {}
        # Resolve display name: try tag_id, normalized tag_id, uid_hex
        for key in (tag_id, _normalize_tag(tag_id), uid_hex):
            if key and key in data:
                display_name = data[key]
                break
        if display_name and isinstance(card_sounds, dict) and display_name in card_sounds:
            name = card_sounds[display_name]
            if name and isinstance(name, str):
                path = os.path.join(SCRIPT_DIR, name)
                if os.path.isfile(path):
                    sound_file = name
    except (json.JSONDecodeError, OSError, KeyError):
        pass
    return display_name, sound_file


def play_scan_sound(tag_id: str, uid_hex: str) -> None:
    """Play per-card sound or two-tone latch (non-blocking). Only call after scan is persisted.
    If card has a custom sound in _card_sounds and the file exists, play it; else play latch.
    Set RFID_PLAY_SOUND=0 or false in .env to disable."""
    v = os.environ.get("RFID_PLAY_SOUND", "1").strip().lower()
    if v in ("0", "false", "no", "off"):
        return
    _, sound_file = _get_display_name_and_sound(tag_id, uid_hex)
    if sound_file:
        if sound_file == "woof.wav":
            ensure_woof_wav()
        wav_path = os.path.join(SCRIPT_DIR, sound_file)
    else:
        ensure_scan_sound_wav()
        wav_path = SCAN_SOUND_WAV
    if not os.path.isfile(wav_path):
        return
    try:
        subprocess.Popen(
            ["aplay", "-q", "-D", ALSA_DEVICE, wav_path],
            cwd=SCRIPT_DIR,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except (FileNotFoundError, OSError):
        pass


def play_scan_sound_blocking(tag_id: str, uid_hex: str) -> None:
    """Play per-card sound or latch and wait for it to finish (e.g. ~4s for dog bark).
    Used before the voice-announce record sequence so the confirmation plays fully."""
    v = os.environ.get("RFID_PLAY_SOUND", "1").strip().lower()
    if v in ("0", "false", "no", "off"):
        return
    _, sound_file = _get_display_name_and_sound(tag_id, uid_hex)
    if sound_file:
        if sound_file == "woof.wav":
            ensure_woof_wav()
        wav_path = os.path.join(SCRIPT_DIR, sound_file)
    else:
        ensure_scan_sound_wav()
        wav_path = SCAN_SOUND_WAV
    if not os.path.isfile(wav_path):
        return
    try:
        subprocess.run(
            ["aplay", "-q", "-D", ALSA_DEVICE, wav_path],
            cwd=SCRIPT_DIR,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
        )
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
        pass


def run_voice_announce_sequence() -> bool:
    """Call the audio bridge: play 'now recording' tone, record Ns, play latch (done). Returns True if bridge responded ok."""
    url = os.environ.get("AUDIO_BRIDGE_URL", "http://127.0.0.1:18796").rstrip("/")
    seconds = int(os.environ.get("RFID_VOICE_RECORD_SECONDS", "5"))
    seconds = max(1, min(60, seconds))
    body = json.dumps({
        "prompt_path": "audio/recording_start.wav",
        "seconds": seconds,
        "done_tone_path": "rfid/scan_sound.wav",
    }).encode("utf-8")
    req = urllib.request.Request(
        url + "/record_after_prompt",
        data=body,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=seconds + 15) as r:
            if 200 <= r.status < 300:
                data = json.loads(r.read().decode())
                ok = data.get("ok") is True
                if ok:
                    log_msg("Voice sequence OK (recorded then latch)")
                else:
                    err = data.get("error") or "unknown"
                    log_err(f"Voice sequence bridge returned ok=false: {err}")
                return ok
    except urllib.error.URLError as e:
        log_err(f"Voice sequence URL error: {e.reason}")
    except urllib.error.HTTPError as e:
        log_err(f"Voice sequence HTTP {e.code}: {e.read()[:150]}")
    except Exception as e:
        log_err(f"Voice sequence failed: {e}")
    return False


def notify_gateway_rfid_scan(
    tag_id: str, ts_iso: str, hooks_token: str, port: str, chat_id: str
) -> bool:
    """Notify the OpenClaw gateway via /hooks/agent so the agent runs and the reply is delivered to Telegram."""
    if not hooks_token or not port or not chat_id:
        return False
    url = f"http://127.0.0.1:{port}/hooks/agent"
    message = (
        f"RFID scan: {tag_id} at {ts_iso}. (Automated notification — process this event: "
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
                return True
            log_err(f"hooks/agent returned {r.status}")
    except urllib.error.HTTPError as e:
        log_err(f"hooks/agent HTTP {e.code}: {e.read()[:200]}")
    except urllib.error.URLError as e:
        log_err(f"hooks/agent URL error: {e.reason}")
    except Exception as e:
        log_err(f"hooks/agent notify: {e}")
    return False


def main():
    load_env()
    voice_announce = os.environ.get("RFID_VOICE_ANNOUNCE", "0").strip().lower() in ("1", "true", "yes")
    log_msg(f"RFID daemon starting: voice_announce={1 if voice_announce else 0} (set RFID_VOICE_ANNOUNCE=1 in .env for record-after-scan)")
    if voice_announce:
        ensure_scan_sound_wav()  # So audio bridge can play latch after record
        if not audio_bridge_reachable():
            log_err("RFID_VOICE_ANNOUNCE=1 but audio bridge not reachable at startup; voice record will be skipped until bridge is running.")
    token = os.environ.get("TELEGRAM_BOT_TOKEN")
    chat_id = get_telegram_chat_id()
    hooks_token = os.environ.get("OPENCLAW_HOOKS_TOKEN")
    agent_port = get_agent_port()
    if not token:
        print("Need TELEGRAM_BOT_TOKEN in agents/pibot/.env", file=sys.stderr)
        sys.exit(1)
    if not chat_id:
        print(
            "Need channels.telegram.allowFrom in agents/pibot/config/openclaw.json (list with your Telegram user ID).",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        import RPi.GPIO as GPIO
        from mfrc522 import SimpleMFRC522
    except ImportError as e:
        print(f"Import error (run on Pi with SPI enabled, mfrc522, RPi.GPIO): {e}", file=sys.stderr)
        sys.exit(1)

    reader = SimpleMFRC522()
    last_scan_path = os.path.join(SCRIPT_DIR, "last_scan.json")
    watcher_state_path = os.path.join(SCRIPT_DIR, ".watcher_state.json")
    if not os.path.isfile(watcher_state_path):
        try:
            with open(watcher_state_path, "w") as f:
                json.dump({}, f)
        except OSError:
            pass
    last_tag_id = None
    last_send_time = 0.0
    debounce_seconds = 3.0

    def send_telegram(text: str) -> bool:
        try:
            subprocess.run(
                [
                    "curl", "-sf", "-X", "POST",
                    f"https://api.telegram.org/bot{token}/sendMessage",
                    "-d", f"chat_id={chat_id}",
                    "--data-urlencode", f"text={text}",
                ],
                check=True,
                timeout=10,
                capture_output=True,
            )
            return True
        except subprocess.CalledProcessError:
            return False
        except Exception:
            return False

    try:
        while True:
            try:
                id_val, text = reader.read_no_block()
            except Exception:
                id_val, text = None, None
            if id_val is not None:
                tag_id = (text.strip() if text and text.strip() else format(id_val, "x"))
                uid_hex = format(id_val, "x")
                now = time.time()
                is_new = last_tag_id != tag_id or (now - last_send_time) >= debounce_seconds
                if is_new:
                    ts_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                    payload = {
                        "tag_id": tag_id,
                        "uid_hex": uid_hex,
                        "timestamp_iso": ts_iso,
                    }
                    # 1. Persist first: atomic write so we're confident the event is saved
                    tmp = last_scan_path + ".tmp"
                    with open(tmp, "w") as f:
                        json.dump(payload, f, indent=2)
                    os.replace(tmp, last_scan_path)
                    # 2. Notify user via Telegram (best-effort)
                    msg = f"RFID scan: {tag_id} at {ts_iso}"
                    if send_telegram(msg):
                        last_send_time = now
                    # 3. Voice-announce flow: confirmation (dog) → ~0s pause → "recording" chime → record 5s → latch → notify
                    voice_announce = os.environ.get("RFID_VOICE_ANNOUNCE", "0").strip().lower() in ("1", "true", "yes")
                    if voice_announce:
                        # Play confirmation (woof ~3s) and wait for it to finish; then immediately trigger recording chime (no pre-check delay)
                        play_scan_sound_blocking(tag_id, uid_hex)
                        pause_s = max(0, min(30, int(os.environ.get("RFID_VOICE_PAUSE_SECONDS", "0"))))
                        if pause_s > 0:
                            time.sleep(pause_s)
                        if run_voice_announce_sequence():
                            log_msg(f"scan {tag_id}: voice sequence OK")
                        else:
                            log_err("Voice sequence failed (bridge down or error); check daemon.log and audio-bridge.service")
                            play_scan_sound(tag_id, uid_hex)
                    else:
                        play_scan_sound(tag_id, uid_hex)
                    # 4. Then wake the agent via hook (non-blocking)
                    if hooks_token and agent_port and chat_id:
                        notify_gateway_rfid_scan(tag_id, ts_iso, hooks_token, agent_port, chat_id)
                    last_tag_id = tag_id
            time.sleep(0.3)
    except KeyboardInterrupt:
        pass
    finally:
        GPIO.cleanup()


if __name__ == "__main__":
    main()
