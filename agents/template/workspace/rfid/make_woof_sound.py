#!/usr/bin/env python3
"""
Generate a short small-dog "woof" WAV for Lucy Love Card. Uses tones only (stdlib).
Run with --play to hear it before using in the daemon.
"""
import math
import os
import struct
import subprocess
import wave

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_PATH = os.path.join(SCRIPT_DIR, "woof.wav")

SAMPLE_RATE = 22050
AMP = 0.75


def main() -> None:
    # Small-dog "woof": two quick bursts, low then slightly higher
    # Burst 1: ~90 ms, 280 Hz (body of woof)
    # Gap: ~25 ms
    # Burst 2: ~70 ms, 380 Hz (tail)
    b1_freq, b1_dur = 280, 0.09
    gap_dur = 0.025
    b2_freq, b2_dur = 380, 0.07
    fade = int(0.006 * SAMPLE_RATE)

    def ramp(n, total):
        if n <= 0 or total <= 0:
            return 1.0
        return min(1.0, n / total)

    n1 = int(SAMPLE_RATE * b1_dur)
    n_gap = int(SAMPLE_RATE * gap_dur)
    n2 = int(SAMPLE_RATE * b2_dur)

    with wave.open(OUT_PATH, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        for i in range(n1):
            env = ramp(i, fade) * ramp(n1 - i, fade)
            v = int(32767 * AMP * env * math.sin(2 * math.pi * b1_freq * i / SAMPLE_RATE))
            w.writeframes(struct.pack("<h", v))
        for _ in range(n_gap):
            w.writeframes(struct.pack("<h", 0))
        for i in range(n2):
            env = ramp(i, fade) * ramp(n2 - i, fade)
            v = int(32767 * AMP * env * math.sin(2 * math.pi * b2_freq * i / SAMPLE_RATE))
            w.writeframes(struct.pack("<h", v))

    print(f"Wrote {OUT_PATH}")
    if "--play" in os.sys.argv or "-p" in os.sys.argv:
        subprocess.run(["aplay", "-q", "-D", "plughw:2,0", OUT_PATH], cwd=SCRIPT_DIR, check=False)
        print("Played.")


if __name__ == "__main__":
    main()
