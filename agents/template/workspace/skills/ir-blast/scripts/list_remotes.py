#!/usr/bin/env python3
"""Print learned remotes and buttons from workspace/ir-codes/REMOTES.md for the ir-blast skill."""
import os
import re
import sys

def find_workspace():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    # script is workspace/skills/ir-blast/scripts/list_remotes.py
    workspace = os.path.dirname(os.path.dirname(os.path.dirname(script_dir)))
    return workspace

def main():
    root = os.environ.get("IRONCLAW_ROOT")
    workspace = os.path.join(root, "workspace") if root else find_workspace()
    ir_codes = os.path.join(workspace, "ir-codes")
    remotes_path = os.path.join(ir_codes, "REMOTES.md")
    if not os.path.isfile(remotes_path):
        print("No learned remotes (REMOTES.md not found). Run ./scripts/ir-learn.py on the Pi.")
        sys.exit(0)
    with open(remotes_path, "r") as f:
        content = f.read()
    # Parse ## remote and table rows | button | path |
    current_remote = None
    count = 0
    for line in content.splitlines():
        m = re.match(r"^##\s+(.+)$", line.strip())
        if m:
            current_remote = m.group(1).strip()
            continue
        if current_remote and line.strip().startswith("|") and "|" in line and "Button" not in line and "---" not in line:
            parts = [p.strip() for p in line.split("|") if p.strip()]
            if len(parts) >= 2:
                button, path = parts[0], parts[1]
                print(f"{current_remote}\t{button}\t{path}")
                count += 1
    if count == 0:
        print("No learned remotes. Run ./scripts/ir-learn.py on the Pi.")

if __name__ == "__main__":
    main()
