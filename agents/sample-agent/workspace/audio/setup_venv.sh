#!/usr/bin/env bash
# Create a venv for the audio bridge and install faster-whisper (avoids system pip on Raspbian).
# Run once on the Pi: bash agents/pibot/workspace/audio/setup_venv.sh
# Then start the bridge with: agents/pibot/workspace/audio/.venv/bin/python audio_bridge_service.py
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
if [[ ! -d "$VENV_DIR" ]]; then
  python3 -m venv "$VENV_DIR"
  echo "Created venv at $VENV_DIR"
fi
"$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements-audio.txt"
echo "Done. Run the bridge with: $VENV_DIR/bin/python $SCRIPT_DIR/audio_bridge_service.py"
