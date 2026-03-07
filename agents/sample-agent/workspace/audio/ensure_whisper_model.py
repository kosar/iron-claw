#!/usr/bin/env python3
"""
Ensure local Whisper model is installed (faster-whisper). Run on the Pi host once.
Downloads the model on first run; subsequent transcribes use the cache.
Usage: python3 ensure_whisper_model.py [model_name]
Default model: base.en (good balance of speed/quality on Pi). Alternatives: tiny.en, small.en.
"""
import os
import sys

def main():
    model = (sys.argv[1] if len(sys.argv) > 1 else os.environ.get("WHISPER_MODEL", "base.en")).strip()
    try:
        from faster_whisper import WhisperModel
    except ImportError:
        print("Install faster-whisper on the host first: pip install faster-whisper", file=sys.stderr)
        sys.exit(1)
    print(f"Loading model {model} (first run may download)...", file=sys.stderr)
    WhisperModel(model, device="cpu", compute_type="int8")
    print("OK: model ready for transcription.", file=sys.stderr)


if __name__ == "__main__":
    main()
