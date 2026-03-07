#!/usr/bin/env python3
"""
Audio bridge service for pibot. Runs on the Raspberry Pi host (not in Docker).
Manages microphone capture and playback: play WAV, record N seconds, or run the
RFID voice-announce sequence (play prompt → record → play done tone).
Uses ALSA (aplay/arecord). USB webcam mic: set AUDIO_CAPTURE_DEVICE (e.g. plughw:1,0)
and optionally run gain-max script so capture is loud enough.

Port: 18796. Override with AUDIO_BRIDGE_PORT. Bind 0.0.0.0 so container (host.docker.internal) can reach.
"""

import json
import os
import subprocess
import sys
import tempfile
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
WORKSPACE_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
AUDIO_DIR = SCRIPT_DIR
DEFAULT_PORT = 18796
# Playback: Pi 3.5mm = plughw:2,0. Override with AUDIO_PLAY_DEVICE.
# Capture: USB mic often plughw:1,0. Override with AUDIO_CAPTURE_DEVICE.
ALSA_PLAY_DEVICE = os.environ.get("AUDIO_PLAY_DEVICE", "plughw:2,0")
ALSA_CAPTURE_DEVICE = os.environ.get("AUDIO_CAPTURE_DEVICE", "default")
# Capture gain (1-100). Default 80% to reduce distortion; set AUDIO_CAPTURE_GAIN_PERCENT=100 to match old behavior.
CAPTURE_GAIN_PERCENT = max(1, min(100, int(os.environ.get("AUDIO_CAPTURE_GAIN_PERCENT", "80"))))
LAST_RECORD_PATH = os.path.join(AUDIO_DIR, "last_record.wav")
# Paths relative to workspace (host: agents/pibot/workspace/...)
RFID_SCAN_SOUND = os.path.join(WORKSPACE_ROOT, "rfid", "scan_sound.wav")
PROMPT_ANNOUNCE = os.path.join(AUDIO_DIR, "prompt_announce.wav")
RECORDING_START = os.path.join(AUDIO_DIR, "recording_start.wav")  # distinct "now recording" tone
MAX_RECORD_SECONDS = 60
DEFAULT_RECORD_SECONDS = 10
SAMPLE_RATE = 16000
CHANNELS = 1


def _json_resp(handler, code: int, obj: dict) -> None:
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json")
    handler.end_headers()
    handler.wfile.write(json.dumps(obj).encode())


def _read_json_body(handler) -> dict:
    length = int(handler.headers.get("Content-Length", 0))
    if length <= 0:
        return {}
    raw = handler.rfile.read(length)
    try:
        return json.loads(raw.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return {}


def _play_wav(wav_path: str, device: str = ALSA_PLAY_DEVICE) -> bool:
    """Play a WAV file via aplay. Blocking. Returns True on success."""
    if not os.path.isfile(wav_path):
        return False
    try:
        subprocess.run(
            ["aplay", "-q", "-D", device, wav_path],
            capture_output=True,
            timeout=30,
            check=True,
        )
        return True
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False


def _max_capture_gain() -> None:
    """Set microphone/capture volume to CAPTURE_GAIN_PERCENT for the capture device.
    USB devices often expose 'Mic' or 'Capture'. Default 80% to avoid distortion."""
    device = ALSA_CAPTURE_DEVICE
    card = "0"
    if device.startswith("plughw:") and "," in device:
        card = device.split(":")[1].split(",")[0]
    gain = f"{CAPTURE_GAIN_PERCENT}%"
    for ctrl in ("Mic", "Capture", "Mic Capture Volume"):
        try:
            subprocess.run(
                ["amixer", "-c", card, "set", ctrl, gain],
                capture_output=True,
                timeout=5,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass


def _record_seconds(seconds: int, out_path: str) -> tuple[bool, str]:
    """Record from ALSA to out_path for `seconds`. Returns (ok, error_msg)."""
    if seconds <= 0 or seconds > MAX_RECORD_SECONDS:
        return False, f"seconds must be 1..{MAX_RECORD_SECONDS}"
    _max_capture_gain()
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    tmp = out_path + ".tmp"
    try:
        cmd = [
            "arecord",
            "-q",
            "-D", ALSA_CAPTURE_DEVICE,
            "-f", "S16_LE",
            "-r", str(SAMPLE_RATE),
            "-c", str(CHANNELS),
            "-d", str(seconds),
            tmp,
        ]
        subprocess.run(cmd, capture_output=True, timeout=seconds + 10, check=True)
        if os.path.isfile(tmp):
            os.replace(tmp, out_path)
            return True, ""
        return False, "arecord did not produce output"
    except FileNotFoundError:
        return False, "arecord not installed (alsa-utils)"
    except subprocess.CalledProcessError as e:
        return False, (e.stderr and e.stderr.decode()[:200]) or "arecord failed"
    except subprocess.TimeoutExpired:
        if os.path.isfile(tmp):
            try:
                os.replace(tmp, out_path)
                return True, ""
            except OSError:
                pass
        return False, "record timeout"
    finally:
        if os.path.isfile(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


def record_after_prompt(
    prompt_wav: str,
    seconds: int,
    done_tone_wav: str,
    out_path: str,
) -> tuple[bool, str]:
    """Play prompt, record for seconds, play done tone. Write WAV to out_path. Returns (ok, error_msg)."""
    if not os.path.isfile(prompt_wav):
        return False, f"prompt file not found: {prompt_wav}"
    if not _play_wav(prompt_wav):
        return False, "failed to play prompt"
    ok, err = _record_seconds(seconds, out_path)
    if not ok:
        return False, err
    if os.path.isfile(done_tone_wav):
        _play_wav(done_tone_wav)
    return True, ""


# Lazy-loaded local Whisper model (faster-whisper). No paid API.
_whisper_model = None
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "base.en")


def _transcribe_wav(wav_path: str) -> tuple[bool, str]:
    """Transcribe WAV using local faster-whisper. Returns (ok, text_or_error_message)."""
    global _whisper_model
    if not os.path.isfile(wav_path) or os.path.getsize(wav_path) == 0:
        return False, "file missing or empty"
    try:
        from faster_whisper import WhisperModel
    except ImportError:
        return False, "faster-whisper not installed. On the host run: pip install faster-whisper"
    try:
        if _whisper_model is None:
            _whisper_model = WhisperModel(WHISPER_MODEL, device="cpu", compute_type="int8")
        segments, _ = _whisper_model.transcribe(wav_path)
        text = " ".join(s.text for s in segments if s.text).strip()
        return True, text or ""
    except Exception as e:
        return False, str(e)[:200]


def ensure_prompt_announce_wav() -> None:
    """Create a short 'go' tone for prompt_announce.wav if missing (stdlib only)."""
    if os.path.isfile(PROMPT_ANNOUNCE):
        return
    try:
        import math
        import struct
        import wave
        rate = 22050
        freq, dur = 440, 0.5
        n = int(rate * dur)
        fade = int(0.05 * rate)
        with wave.open(PROMPT_ANNOUNCE, "w") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            for i in range(n):
                env = min(1.0, i / fade) * min(1.0, (n - i) / fade) if fade else 1.0
                v = int(32767 * 0.6 * env * math.sin(2 * math.pi * freq * i / rate))
                w.writeframes(struct.pack("<h", v))
    except OSError:
        pass


def ensure_recording_start_wav() -> None:
    """Create a distinct 'now recording' tone (two quick beeps, different pitch) if missing."""
    if os.path.isfile(RECORDING_START):
        return
    try:
        import math
        import struct
        import wave
        rate = 22050
        # Two short beeps: 660 Hz then 880 Hz, ~0.25s each, 0.1s gap — clearly "recording"
        beeps = [(660, 0.25), (0, 0.1), (880, 0.25)]
        frames = []
        for freq, dur in beeps:
            n = int(rate * dur)
            fade = min(int(0.03 * rate), n // 4)
            for i in range(n):
                if freq == 0:
                    v = 0
                else:
                    env = min(1.0, i / fade) * min(1.0, (n - i) / fade) if fade else 1.0
                    v = int(32767 * 0.5 * env * math.sin(2 * math.pi * freq * i / rate))
                frames.append(struct.pack("<h", v))
        with wave.open(RECORDING_START, "w") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            for b in frames:
                w.writeframes(b)
    except OSError:
        pass


def main() -> None:
    port = int(os.environ.get("AUDIO_BRIDGE_PORT", DEFAULT_PORT))
    ensure_prompt_announce_wav()
    ensure_recording_start_wav()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = urlparse(self.path).path.rstrip("/")
            if path == "/health":
                _json_resp(self, 200, {
                    "ok": True,
                    "service": "audio-bridge",
                    "port": port,
                })
                return
            self.send_response(404)
            self.end_headers()

        def do_POST(self):
            path = urlparse(self.path).path.rstrip("/")
            body = _read_json_body(self)
            try:
                if path == "/play":
                    # { "path": "workspace/audio/foo.wav" or "rfid/scan_sound.wav" }
                    rel = (body.get("path") or "").strip()
                    if not rel:
                        _json_resp(self, 400, {"ok": False, "error": "path required"})
                        return
                    if rel.startswith("workspace/"):
                        rel = rel[len("workspace/"):]
                    wav_path = os.path.join(WORKSPACE_ROOT, rel)
                    if not os.path.normpath(wav_path).startswith(WORKSPACE_ROOT):
                        _json_resp(self, 400, {"ok": False, "error": "path outside workspace"})
                        return
                    ok = _play_wav(wav_path)
                    _json_resp(self, 200, {"ok": ok, "path": rel})
                    return
                if path == "/record":
                    seconds = int(body.get("seconds", DEFAULT_RECORD_SECONDS))
                    seconds = max(1, min(MAX_RECORD_SECONDS, seconds))
                    out_path = LAST_RECORD_PATH
                    ok, err = _record_seconds(seconds, out_path)
                    if ok:
                        _json_resp(self, 200, {"ok": True, "path": "workspace/audio/last_record.wav"})
                    else:
                        _json_resp(self, 200, {"ok": False, "error": err})
                    return
                if path == "/record_after_prompt":
                    # Used by RFID daemon: play prompt → record → play done tone.
                    prompt_rel = (body.get("prompt_path") or "audio/prompt_announce.wav").strip()
                    if prompt_rel.startswith("workspace/"):
                        prompt_rel = prompt_rel[len("workspace/"):]
                    prompt_wav = os.path.join(WORKSPACE_ROOT, prompt_rel)
                    if "recording_start" in prompt_rel:
                        ensure_recording_start_wav()
                        prompt_wav = RECORDING_START
                    seconds = int(body.get("seconds", DEFAULT_RECORD_SECONDS))
                    seconds = max(1, min(MAX_RECORD_SECONDS, seconds))
                    done_rel = (body.get("done_tone_path") or "rfid/scan_sound.wav").strip()
                    if done_rel.startswith("workspace/"):
                        done_rel = done_rel[len("workspace/"):]
                    done_tone_wav = os.path.join(WORKSPACE_ROOT, done_rel)
                    out_path = LAST_RECORD_PATH
                    ok, err = record_after_prompt(prompt_wav, seconds, done_tone_wav, out_path)
                    if ok:
                        _json_resp(self, 200, {"ok": True, "path": "workspace/audio/last_record.wav"})
                    else:
                        _json_resp(self, 200, {"ok": False, "error": err})
                    return
                if path == "/transcribe":
                    # Local Whisper (faster-whisper on host). No paid API.
                    rel = (body.get("path") or "audio/last_record.wav").strip()
                    if rel.startswith("workspace/"):
                        rel = rel[len("workspace/"):]
                    wav_path = os.path.join(WORKSPACE_ROOT, rel)
                    if not os.path.normpath(wav_path).startswith(WORKSPACE_ROOT):
                        _json_resp(self, 400, {"ok": False, "error": "path outside workspace"})
                        return
                    ok, text_or_err = _transcribe_wav(wav_path)
                    if ok:
                        _json_resp(self, 200, {"ok": True, "text": text_or_err})
                    else:
                        _json_resp(self, 200, {"ok": False, "error": text_or_err})
                    return
            except (ValueError, TypeError) as e:
                _json_resp(self, 400, {"ok": False, "error": str(e)})
                return
            self.send_response(404)
            self.end_headers()

        def log_message(self, format, *args):
            pass

    server = HTTPServer(("0.0.0.0", port), Handler)
    print(f"Audio bridge on 0.0.0.0:{port} (override with AUDIO_BRIDGE_PORT)", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
