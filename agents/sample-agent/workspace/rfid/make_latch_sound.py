#!/usr/bin/env python3
"""
Generate a two-tone "latch/plug connect" WAV for RFID scan feedback.
Run this to create scan_sound.wav and play it so you can give feedback before we put it in the daemon.
Usage: python3 make_latch_sound.py [--play]
"""
import argparse
import math
import os
import struct
import subprocess
import wave

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_PATH = os.path.join(SCRIPT_DIR, "scan_sound.wav")

SAMPLE_RATE = 22050
AMP = 0.8


def write_frame(w, i: int, freq: float, phase_offset: float, envelope: float = 1.0) -> None:
    """Write one sample: sine at freq with optional envelope (for soft start/end)."""
    value = int(32767 * AMP * envelope * math.sin(2 * math.pi * freq * i / SAMPLE_RATE + phase_offset))
    w.writeframes(struct.pack("<h", value))


def ramp(n: int, total: int) -> float:
    """Linear ramp 0->1 over first n samples (fade in)."""
    if n <= 0 or total <= 0:
        return 1.0
    return min(1.0, n / total)


def main() -> None:
    # Two-tone sequence: low "chunk" (plug seating) then higher "click" (latch)
    # Tone 1: 380 Hz, ~0.12 s, slight fade in
    # Gap: ~0.04 s
    # Tone 2: 760 Hz, ~0.12 s
    freq1, dur1 = 380, 0.12
    gap_dur = 0.04
    freq2, dur2 = 760, 0.12
    fade_samples = int(0.008 * SAMPLE_RATE)  # 8 ms fade to avoid clicks

    n1 = int(SAMPLE_RATE * dur1)
    n_gap = int(SAMPLE_RATE * gap_dur)
    n2 = int(SAMPLE_RATE * dur2)

    with wave.open(OUT_PATH, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        # Tone 1
        for i in range(n1):
            env = ramp(i, fade_samples) * ramp(n1 - i, fade_samples)
            write_frame(w, i, freq1, 0, env)
        # Gap
        for _ in range(n_gap):
            w.writeframes(struct.pack("<h", 0))
        # Tone 2
        for i in range(n2):
            env = ramp(i, fade_samples) * ramp(n2 - i, fade_samples)
            write_frame(w, i, freq2, 0, env)

    print(f"Wrote {OUT_PATH}")
    if "--play" in os.sys.argv or "-p" in os.sys.argv:
        subprocess.run(["aplay", "-q", "-D", "plughw:2,0", OUT_PATH], cwd=SCRIPT_DIR, check=False)
        print("Played.")


if __name__ == "__main__":
    main()
