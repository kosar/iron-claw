#!/usr/bin/env python3
"""Emit a learned IR button by remote and button name. Usage: emit.py <remote> <button> [device]"""
import os
import re
import subprocess
import sys
import tempfile
import time

def find_workspace():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    workspace = os.path.dirname(os.path.dirname(os.path.dirname(script_dir)))
    return workspace

def main():
    if len(sys.argv) < 3:
        print("Usage: emit.py <remote> <button> [device]", file=sys.stderr)
        sys.exit(1)
    remote = sys.argv[1].strip().lower().replace(" ", "_")
    button = sys.argv[2].strip().lower().replace(" ", "_")
    device = sys.argv[3] if len(sys.argv) > 3 else os.environ.get("IR_LIRC_DEVICE", "/dev/lirc0")

    root = os.environ.get("IRONCLAW_ROOT")
    workspace = os.path.join(root, "workspace") if root else find_workspace()
    ir_codes = os.path.join(workspace, "ir-codes")
    remotes_path = os.path.join(ir_codes, "REMOTES.md")
    if not os.path.isfile(remotes_path):
        print("REMOTES.md not found. Run ./scripts/ir-learn.py on the Pi.", file=sys.stderr)
        sys.exit(1)
    with open(remotes_path, "r") as f:
        content = f.read()
    current_remote = None
    ir_file = None
    for line in content.splitlines():
        m = re.match(r"^##\s+(.+)$", line.strip())
        if m:
            current_remote = m.group(1).strip()
            continue
        if current_remote == remote and line.strip().startswith("|") and "|" in line and "Button" not in line and "---" not in line:
            parts = [p.strip() for p in line.split("|") if p.strip()]
            if len(parts) >= 2 and parts[0] == button:
                ir_file = os.path.join(ir_codes, parts[1])
                break
    if not ir_file or not os.path.isfile(ir_file):
        print(f"Button '{button}' not found for remote '{remote}'. Check REMOTES.md or learn with ir-learn.py.", file=sys.stderr)
        sys.exit(1)
    # Convert raw durations (one per line, pulse/space alternating) to ir-ctl mode2 format
    # so ir-ctl parses unambiguously: "pulse 2250\nspace 850\n..."
    with open(ir_file, "r") as f:
        lines = [ln.strip() for ln in f if ln.strip()]
    try:
        send_lines = [("pulse" if i % 2 == 0 else "space") + " " + lines[i] for i in range(len(lines))]
    except (IndexError, ValueError):
        send_lines = []
    if not send_lines:
        print("IR file empty or invalid.", file=sys.stderr)
        sys.exit(1)
    fd, tmp_path = tempfile.mkstemp(suffix=".ir", prefix="ir_")
    try:
        os.write(fd, ("\n".join(send_lines) + "\n").encode())
        os.close(fd)
        fd = None
        send_file = tmp_path
    except Exception:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        send_file = ir_file
        tmp_path = None
    # Tuned for this fan: 2 blasts, 0.2s gap = one reliable “button press” (on and stays on). More repeats can toggle off.
    # One blast = one button press. Multiple blasts make the fan see multiple presses (toggle on then off).
    REPEATS = 1
    GAP_SEC = 0.2
    try:
        for _ in range(REPEATS):
            subprocess.run(
                ["ir-ctl", "-d", device, "-e", "1", "-c", "38000", "--send=" + send_file],
                check=True,
                capture_output=True,
                timeout=10,
            )
            if REPEATS > 1:
                time.sleep(GAP_SEC)
    except FileNotFoundError:
        print("ir-ctl not found. Install v4l-utils (e.g. apt install v4l-utils).", file=sys.stderr)
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print("ir-ctl timed out. Check dongle and device.", file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as e:
        stderr = e.stderr.decode(errors="replace") if e.stderr else str(e)
        if "Permission denied" in stderr or "permission" in stderr.lower():
            print(f"IR device {device}: permission denied. On host run: sudo chmod 666 {device} or install scripts/99-lirc-permissions.rules (see docs/IR-DONGLE.md).", file=sys.stderr)
        elif "No such file" in stderr or "No such device" in stderr or "not found" in stderr.lower():
            print(f"IR device {device} not found. Ensure dongle is plugged in and mceusb is bound (see docs/IR-DONGLE.md).", file=sys.stderr)
        else:
            print(f"ir-ctl failed: {stderr}", file=sys.stderr)
        sys.exit(1)
    finally:
        if tmp_path and os.path.isfile(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

if __name__ == "__main__":
    main()
