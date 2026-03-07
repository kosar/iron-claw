#!/usr/bin/env python3
"""
Capture raw IR (pulse/space) from a Linux LIRC device — e.g. Microsoft eHome
IR Transceiver (045e:006d) via the kernel mceusb driver.

Usage:
  ./scripts/ir-receive.py              # use /dev/lirc0
  ./scripts/ir-receive.py -d /dev/lirc1
  ./scripts/ir-receive.py --summary    # one-line timing summary per key
  ./scripts/ir-receive.py --summary --record saved.ir   # save last key to file
  ./scripts/ir-receive.py --record file.ir --oneshot    # capture one button then exit (for ir-learn)
  ./scripts/ir-blast.sh saved.ir       # blast saved waveform (needs v4l-utils)

Recorded files are in ir-ctl format (one pulse/space duration per line, µs).
Requires: device node (e.g. /dev/lirc0) provided by mceusb. If the dongle
appears as "eHome Remote Control Keyboard" only, bind it to mceusb — see
docs/IR-DONGLE.md.
"""

import argparse
import array
import fcntl
import os
import struct
import sys

# LIRC kernel ABI (see /usr/include/linux/lirc.h)
LIRC_VALUE_MASK = 0x00FFFFFF
LIRC_MODE2_SPACE     = 0x00000000
LIRC_MODE2_PULSE     = 0x01000000
LIRC_MODE2_FREQUENCY = 0x02000000
LIRC_MODE2_TIMEOUT   = 0x03000000
LIRC_MODE2_OVERFLOW  = 0x04000000
LIRC_MODE_MODE2      = 0x00000004

# ioctl: _IOR('i', 0x02, __u32), _IOW('i', 0x12, __u32)
LIRC_GET_REC_MODE = 0x8004_6902
LIRC_SET_REC_MODE = 0xC004_6912


def find_lirc_devices():
    """Return list of /dev/lircN that exist."""
    devs = []
    for n in range(8):
        path = f"/dev/lirc{n}"
        if os.path.exists(path):
            devs.append(path)
    return devs


def set_mode2(fd):
    """Set receive mode to LIRC_MODE_MODE2 (raw pulse/space)."""
    buf = array.array("I", [LIRC_MODE_MODE2])
    try:
        fcntl.ioctl(fd, LIRC_SET_REC_MODE, buf, True)
    except OSError as e:
        raise SystemExit(f"LIRC_SET_REC_MODE failed: {e}") from e


def read_one(fd):
    """Read one LIRC mode2 sample: (kind_str, duration_us)."""
    raw = os.read(fd, 4)
    if len(raw) != 4:
        return None, 0
    val, = struct.unpack("I", raw)
    duration = val & LIRC_VALUE_MASK
    mode = val & 0xFF000000
    if mode == LIRC_MODE2_PULSE:
        return "pulse", duration
    if mode == LIRC_MODE2_SPACE:
        return "space", duration
    if mode == LIRC_MODE2_TIMEOUT:
        return "timeout", duration
    if mode == LIRC_MODE2_FREQUENCY:
        return "frequency", duration
    if mode == LIRC_MODE2_OVERFLOW:
        return "overflow", duration
    return "unknown", duration


def main():
    ap = argparse.ArgumentParser(description="Capture raw IR from /dev/lircN (e.g. Microsoft eHome dongle)")
    ap.add_argument("-d", "--device", default="/dev/lirc0", help="LIRC device (default: /dev/lirc0)")
    ap.add_argument("--list", action="store_true", help="List /dev/lirc* and exit")
    ap.add_argument("--summary", action="store_true", help="Print one-line pulse/space timing summary per key")
    ap.add_argument("--record", metavar="FILE", help="Save last captured frame to FILE (ir-ctl format) for ir-blast.sh")
    ap.add_argument("--oneshot", action="store_true", help="With --record: exit after saving first frame (for ir-learn)")
    args = ap.parse_args()

    if args.list:
        devs = find_lirc_devices()
        if not devs:
            print("No /dev/lirc* devices found. Ensure mceusb is bound to the IR dongle (see docs/IR-DONGLE.md).")
            sys.exit(1)
        for d in devs:
            print(d)
        sys.exit(0)

    if not os.path.exists(args.device):
        devs = find_lirc_devices()
        print(f"Device {args.device} not found.", file=sys.stderr)
        if devs:
            print(f"Available: {' '.join(devs)}", file=sys.stderr)
        else:
            print("No /dev/lirc* devices. Check driver binding (docs/IR-DONGLE.md).", file=sys.stderr)
        sys.exit(1)

    try:
        fd = os.open(args.device, os.O_RDONLY)
    except OSError as e:
        raise SystemExit(f"Open {args.device}: {e}") from e

    # Ensure raw mode
    try:
        result = array.array("I", [0])
        fcntl.ioctl(fd, LIRC_GET_REC_MODE, result, True)
        if result[0] != LIRC_MODE_MODE2:
            set_mode2(fd)
    except OSError as e:
        os.close(fd)
        raise SystemExit(f"LIRC mode: {e}") from e

    print(f"Reading raw IR from {args.device}. Point your remote at the dongle (Ctrl+C to stop).", file=sys.stderr)
    print("", file=sys.stderr)

    frame = []  # list of (kind, duration) for --summary

    try:
        while True:
            kind, duration = read_one(fd)
            if kind is None:
                continue
            if args.summary or args.record:
                if kind == "timeout" and frame:
                    # Strip leading junk spaces (idle/max or tiny glitch)
                    while frame and frame[0][0] == "space":
                        frame.pop(0)
                    if frame:
                        if args.summary:
                            parts = [f"{k[0][0]}{d}" for k, d in frame]
                            print(" ".join(parts))
                        if args.record:
                            # ir-ctl format: one duration per line, alternating pulse/space
                            with open(args.record, "w") as f:
                                for k, d in frame:
                                    f.write(f"{d}\n")
                            print(f"Recorded to {args.record}", file=sys.stderr)
                            if args.oneshot:
                                sys.exit(0)
                    frame = []
                elif kind in ("pulse", "space"):
                    frame.append((kind, duration))
            else:
                label = kind.upper()
                print(f"{label} {duration}")

    except KeyboardInterrupt:
        pass
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
