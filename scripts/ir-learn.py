#!/usr/bin/env python3
"""
Interactive IR remote learner: capture button presses, name them, and store
in a catalog so OpenClaw (or ir-blast.sh) can replay by name.

Run on the Raspberry Pi (where the IR dongle is). Output goes to the agent
workspace so the ir-blast skill can emit buttons by name.

Usage:
  ./scripts/ir-learn.py
  ./scripts/ir-learn.py --output agents/pibot/workspace/ir-codes
  ./scripts/ir-learn.py -d /dev/lirc0

Flow:
  1. "Remote name (e.g. fan_remote): " → you type the remote id
  2. "Press a button." → you point the remote and press
  3. "Got it. Name for this button (e.g. power): " → you name it (saved as <remote>/<button>.ir)
  4. Repeat 2–3 for more buttons; Enter with no name or "done" to finish this remote
  5. Catalog updated in REMOTES.md; agent can list and blast by remote + button name
"""

import argparse
import os
import re
import subprocess
import sys

# Default: pibot workspace ir-codes (relative to repo root = parent of scripts/)
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
DEFAULT_OUTPUT = os.path.join(REPO_ROOT, "agents", "pibot", "workspace", "ir-codes")


def sanitize(s: str) -> str:
    """Lowercase, replace spaces/special with underscore, collapse multiple underscores."""
    s = s.strip().lower()
    s = re.sub(r"[^a-z0-9]+", "_", s)
    return re.sub(r"_+", "_", s).strip("_") or "button"


def capture_one_button(device: str, script_path: str, tmp_path: str) -> bool:
    """Run ir-receive.py --record tmp --oneshot; return True if a frame was captured."""
    cmd = [
        sys.executable,
        script_path,
        "--record", tmp_path,
        "--oneshot",
        "-d", device,
    ]
    try:
        subprocess.run(cmd, check=True, capture_output=True, timeout=30)
        return os.path.isfile(tmp_path) and os.path.getsize(tmp_path) > 0
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return False


def ensure_remote_section(lines: list, remote: str) -> list:
    """Ensure REMOTES.md has a ## remote section and a table header; return updated lines."""
    remote_header = f"## {remote}"
    table_header = "| Button | File |"
    table_sep = "|--------|------|"
    out = []
    in_section = False
    table_started = False
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip() == remote_header:
            in_section = True
            out.append(line)
            i += 1
            if i < len(lines) and lines[i].strip() == table_header:
                out.append(lines[i])
                i += 1
                if i < len(lines) and "---" in lines[i]:
                    out.append(lines[i])
                    i += 1
                table_started = True
            continue
        if in_section and table_started:
            # Already in table; we'll append new rows before the next ##
            out.append(line)
            i += 1
            continue
        if line.strip().startswith("## ") and in_section:
            in_section = False
        out.append(line)
        i += 1
    return out


def add_button_to_remotes_md(remotes_path: str, remote: str, button: str, rel_file: str) -> None:
    """Append a row to the remote's table in REMOTES.md; create section/table if missing."""
    content = ""
    if os.path.isfile(remotes_path):
        with open(remotes_path, "r") as f:
            content = f.read()
    lines = content.splitlines()

    remote_header = f"## {remote}"
    table_header = "| Button | File |"
    table_sep = "|--------|------|"
    new_row = f"| {button} | {rel_file} |"

    if remote_header not in content:
        if lines and not lines[-1].strip() == "":
            lines.append("")
        lines.append(remote_header)
        lines.append("")
        lines.append(table_header)
        lines.append(table_sep)
        lines.append(new_row)
    else:
        # Find ## remote, then insert new row before the next ## (or at end)
        section_start = None
        for i, line in enumerate(lines):
            if line.strip() == remote_header:
                section_start = i
                break
        if section_start is None:
            lines.append("")
            lines.append(remote_header)
            lines.append("")
            lines.append(table_header)
            lines.append(table_sep)
            lines.append(new_row)
        else:
            insert_before = len(lines)
            for j in range(section_start + 1, len(lines)):
                if lines[j].strip().startswith("## "):
                    insert_before = j
                    break
            lines.insert(insert_before, new_row)

    with open(remotes_path, "w") as f:
        f.write("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser(description="Learn IR buttons: capture, name, save to catalog for ir-blast skill")
    ap.add_argument("-d", "--device", default="/dev/lirc0", help="LIRC device")
    ap.add_argument("-o", "--output", default=DEFAULT_OUTPUT, help="Output dir for ir-codes (default: pibot workspace ir-codes)")
    args = ap.parse_args()

    script_path = os.path.join(SCRIPT_DIR, "ir-receive.py")
    if not os.path.isfile(script_path):
        print(f"ir-receive.py not found at {script_path}", file=sys.stderr)
        sys.exit(1)
    if not os.path.exists(args.device):
        print(f"Device {args.device} not found. Plug in the IR dongle and ensure mceusb is bound.", file=sys.stderr)
        sys.exit(1)

    os.makedirs(args.output, exist_ok=True)
    remotes_path = os.path.join(args.output, "REMOTES.md")
    if not os.path.isfile(remotes_path):
        with open(remotes_path, "w") as f:
            f.write("# Learned IR remotes\n\n")
            f.write("Buttons learned here can be replayed by the **ir-blast** skill (remote name + button name).\n\n")

    print("Remote name (e.g. fan_remote): ", end="", flush=True)
    remote_raw = input().strip() or "remote"
    remote = sanitize(remote_raw) or "remote"
    remote_dir = os.path.join(args.output, remote)
    os.makedirs(remote_dir, exist_ok=True)

    tmp_ir = os.path.join(args.output, ".tmp_one.ir")
    try:
        while True:
            print("Press a button.", flush=True)
            if not capture_one_button(args.device, script_path, tmp_ir):
                print("No signal captured. Try again (point remote at dongle, then press).", file=sys.stderr)
                continue
            print("Got it. Name for this button (e.g. power), or Enter to finish: ", end="", flush=True)
            name_raw = input().strip()
            if not name_raw or name_raw.lower() in ("done", "q", "quit"):
                break
            button = sanitize(name_raw) or "button"
            rel_file = f"{remote}/{button}.ir"
            out_path = os.path.join(args.output, rel_file)
            os.makedirs(os.path.dirname(out_path), exist_ok=True)
            with open(tmp_ir, "r") as f:
                data = f.read()
            with open(out_path, "w") as f:
                f.write(data)
            add_button_to_remotes_md(remotes_path, remote, button, rel_file)
            print(f"Saved: {rel_file}")
    finally:
        if os.path.isfile(tmp_ir):
            try:
                os.remove(tmp_ir)
            except OSError:
                pass

    print("Done. Catalog:", remotes_path)
    print("Blast from CLI: ./scripts/ir-blast.sh <path to .ir file>")
    print("From the agent: use the ir-blast skill with remote and button name.")


if __name__ == "__main__":
    main()
