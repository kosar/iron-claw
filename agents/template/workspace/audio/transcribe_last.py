#!/usr/bin/env python3
"""
Transcribe workspace/audio/last_record.wav using the host audio bridge (local Whisper).
The bridge runs faster-whisper on the host — no paid API. Run from inside the container.
Prints transcript to stdout; on failure prints TRANSCRIBE_FAILED and exits non-zero.
Usage: transcribe_last.py [path_to_wav]
Default path: workspace/audio/last_record.wav (path is relative to workspace for the bridge).
"""
import json
import os
import sys

def main():
    # Optional path override (e.g. audio/last_record.wav); bridge default is last_record.wav
    path_arg = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
    if path_arg and path_arg.startswith("workspace/"):
        path_arg = path_arg[len("workspace/"):]
    if not path_arg:
        path_arg = "audio/last_record.wav"
    url = os.environ.get("AUDIO_BRIDGE_URL", "http://host.docker.internal:18796").rstrip("/")
    try:
        req = __import__("urllib.request").request.Request(
            url + "/transcribe",
            data=json.dumps({"path": path_arg}).encode("utf-8"),
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        with __import__("urllib.request").request.urlopen(req, timeout=60) as r:
            data = json.loads(r.read().decode("utf-8"))
    except Exception:
        print("TRANSCRIBE_FAILED", file=sys.stderr)
        sys.exit(1)
    if not data.get("ok"):
        print("TRANSCRIBE_FAILED", file=sys.stderr)
        sys.exit(1)
    text = (data.get("text") or "").strip()
    if text:
        print(text)


if __name__ == "__main__":
    main()
