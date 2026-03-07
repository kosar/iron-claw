#!/usr/bin/env bash
# Download a sample English speech WAV for testing transcription. Run from repo root or audio dir.
# Usage: bash get_sample_wav.sh [output_path]
# Default: agents/pibot/workspace/audio/sample_speech.wav
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$SCRIPT_DIR/sample_speech.wav}"
curl -sL -o "$OUT" "https://github.com/jameslyons/python_speech_features/raw/master/english.wav"
echo "Downloaded $OUT"
echo "Test: python3 $SCRIPT_DIR/test_transcribe.py $OUT"
