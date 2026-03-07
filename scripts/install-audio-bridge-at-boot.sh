#!/usr/bin/env bash
# Install the audio bridge as a user systemd service so it starts at login (or at boot with linger).
# Run once from the repo root: ./scripts/install-audio-bridge-at-boot.sh
# Requires: faster-whisper installed (pip install --user faster-whisper). This script will try to install it if missing.
set -e
REPO_ROOT="${1:-$HOME/ironclaw}"
AUDIO_DIR="$REPO_ROOT/agents/pibot/workspace/audio"
SERVICE_NAME="audio-bridge.service"
USER_UNIT_DIR="$HOME/.config/systemd/user"
# USB mic device: set from "arecord -L" on the Pi. Common: plughw:CARD=Camera,DEV=0 for USB webcam mic.
AUDIO_CAPTURE_DEVICE="${AUDIO_CAPTURE_DEVICE:-plughw:CARD=Camera,DEV=0}"

if [[ ! -d "$REPO_ROOT" ]]; then
  echo "Repo not found at $REPO_ROOT. Usage: $0 [path-to-ironclaw-repo]" >&2
  exit 1
fi
cd "$REPO_ROOT"

# Ensure faster-whisper is available (user install on Raspbian to avoid venv)
if ! python3 -c "from faster_whisper import WhisperModel" 2>/dev/null; then
  echo "Installing faster-whisper (user install)..."
  pip install --user faster-whisper 2>/dev/null || pip install --break-system-packages faster-whisper 2>/dev/null || true
  if ! python3 -c "from faster_whisper import WhisperModel" 2>/dev/null; then
    echo "Could not install faster-whisper. Run manually: pip install --user faster-whisper" >&2
    exit 1
  fi
fi

mkdir -p "$USER_UNIT_DIR"
cat > "$USER_UNIT_DIR/$SERVICE_NAME" << EOF
# Audio bridge — installed by scripts/install-audio-bridge-at-boot.sh
# Logs: journalctl --user -u audio-bridge.service -f
# Mic: run arecord -L and set AUDIO_CAPTURE_DEVICE in [Service] if needed.

[Unit]
Description=Audio bridge for pibot (mic + playback + transcribe, port 18796)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$REPO_ROOT
Environment=AUDIO_CAPTURE_DEVICE=$AUDIO_CAPTURE_DEVICE
ExecStart=/usr/bin/python3 $AUDIO_DIR/audio_bridge_service.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

echo "Installed $USER_UNIT_DIR/$SERVICE_NAME"
systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"
systemctl --user start "$SERVICE_NAME"
echo "Audio bridge enabled and started. Status:"
systemctl --user status "$SERVICE_NAME" --no-pager || true
echo ""
echo "To have it start at boot without logging in, run once: loginctl enable-linger \$USER"
echo "Logs: journalctl --user -u audio-bridge.service -f"
echo "Prove transcription: python3 $AUDIO_DIR/test_transcribe.py $AUDIO_DIR/sample_speech.wav"