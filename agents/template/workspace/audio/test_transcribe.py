#!/usr/bin/env python3
"""
Minimal test: transcribe a WAV file with faster-whisper. Run from audio dir:
  python3 test_transcribe.py [path.wav]
Default: sample_speech.wav (download with get_sample_wav.sh).
Exit 0 + print transcript on success; exit 1 + print error on failure.
"""
import sys
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_WAV = os.path.join(SCRIPT_DIR, "sample_speech.wav")


def main():
    wav = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_WAV
    if not os.path.isfile(wav):
        print(f"FAIL: file not found: {wav}", file=sys.stderr)
        sys.exit(1)
    try:
        from faster_whisper import WhisperModel
    except ImportError as e:
        print(f"FAIL: faster_whisper not installed: {e}", file=sys.stderr)
        sys.exit(1)
    model_name = os.environ.get("WHISPER_MODEL", "base.en")
    try:
        model = WhisperModel(model_name, device="cpu", compute_type="int8")
        segments, _ = model.transcribe(wav)
        text = " ".join(s.text for s in segments if s.text).strip()
        if text:
            print(text)
            sys.exit(0)
        else:
            print("FAIL: empty transcript", file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        print(f"FAIL: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
