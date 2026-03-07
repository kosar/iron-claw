# Audio bridge (pibot)

The audio bridge runs on the **Raspberry Pi host** and manages microphone capture and playback. The agent (and RFID daemon) talk to it over HTTP so audio stays on the host while the container stays isolated.

## What it does

- **Play WAV:** `POST /play` with `{"path": "rfid/scan_sound.wav"}` — path relative to workspace. Plays through the Pi’s 3.5 mm jack (or `AUDIO_PLAY_DEVICE`).
- **Record N seconds:** `POST /record` with `{"seconds": 10}`. Records from the default ALSA capture device (or `AUDIO_CAPTURE_DEVICE`), writes to `workspace/audio/last_record.wav`. Gain is set before each record (default 80% via `AUDIO_CAPTURE_GAIN_PERCENT` to reduce distortion; override with 1–100).
- **Record after prompt (RFID flow):** `POST /record_after_prompt` with `{"prompt_path": "audio/recording_start.wav", "seconds": 5, "done_tone_path": "rfid/scan_sound.wav"}`. Plays the "now recording" tone, records for N seconds, then plays the done tone (two‑tone latch). Writes to `last_record.wav`.

## Port and env

- **Port:** 18796 (override with `AUDIO_BRIDGE_PORT`).
- **Playback device:** `AUDIO_PLAY_DEVICE` (default `plughw:2,0` for Pi 3.5 mm).
- **Capture device:** `AUDIO_CAPTURE_DEVICE` (default `default`). For a USB webcam mic, use the ALSA device name, e.g. `plughw:1,0` (card 1). List with `arecord -L` on the host.
- **Capture gain:** `AUDIO_CAPTURE_GAIN_PERCENT` (default `80`). Microphone volume 1–100%. Lower values reduce distortion if the mic is hot.

## Running on the Pi

**One-off (foreground):**
```bash
cd ~/ironclaw
/usr/bin/python3 agents/pibot/workspace/audio/audio_bridge_service.py
```
Requires `faster-whisper` installed (see Dependencies).

**Start at boot (recommended):** Run once from repo root:
```bash
cd ~/ironclaw
./scripts/install-audio-bridge-at-boot.sh
```
That script installs **faster-whisper** if missing (`pip install --user faster-whisper`), installs a **user systemd service** (`audio-bridge.service`) with `AUDIO_CAPTURE_DEVICE` set for a USB webcam mic, and enables and starts it. No venv. After reboot (or login), the bridge starts automatically. For **boot without logging in**: `loginctl enable-linger $USER`. See `docs/RASPBERRY-PI-RUNBOOK.md`.

## Dependencies

- **alsa-utils:** `aplay`, `arecord`, `amixer` (e.g. `sudo apt install alsa-utils`).
- **faster-whisper:** Install on the host so the bridge can transcribe. On Raspbian: `pip install --user faster-whisper` (first run downloads the model, e.g. base.en). No virtual environment.
- **Capture device:** Set `AUDIO_CAPTURE_DEVICE` if your mic is not the default. Run `arecord -L` and use the device name (e.g. `plughw:CARD=Camera,DEV=0` for a USB webcam mic). The install script sets this in the systemd unit.
- **Sniff test (prove transcription works):** Download a sample WAV and transcribe it:
  ```bash
  bash agents/pibot/workspace/audio/get_sample_wav.sh
  python3 agents/pibot/workspace/audio/test_transcribe.py agents/pibot/workspace/audio/sample_speech.wav
  ```
  Expected output: a short English phrase (e.g. "Hello from the Children of Planet Earth."). If that works, the bridge’s `/transcribe` will work too.

## Transcription (local Whisper, no paid API)

- **POST /transcribe** with `{"path": "audio/last_record.wav"}` (path relative to workspace). The bridge runs **faster-whisper** locally and returns `{"ok": true, "text": "..."}`. No OpenAI or other paid API. The container script `transcribe_last.py` calls this endpoint.
- **Why not Ollama?** Ollama has no audio input API (it supports text and images only). We use **faster-whisper** on the host. Install: `pip install --user faster-whisper` (no venv).

## RFID voice announce

When `RFID_VOICE_ANNOUNCE=1` and `AUDIO_BRIDGE_URL` point at this service, the RFID daemon calls `/record_after_prompt` on each scan: user hears the prompt, speaks (e.g. “I just fed Lucy”), then hears the latch. The recording is at `workspace/audio/last_record.wav` for the agent. Sequence: confirmation (e.g. dog) plays fully, 5s pause, "now recording" tone, 5s record, latch, then agent is notified. No transcript in Telegram? Set RFID_VOICE_ANNOUNCE=1 and ensure the bridge is running. Pi slow? Set WHISPER_MODEL=tiny.en in the bridge env.

## Prompt WAV

`prompt_announce.wav` is created automatically if missing (short 440 Hz). `recording_start.wav` is auto-created (two-beep "now recording"). Replace either with custom WAVs if you prefer.
