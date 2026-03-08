---
name: rfid-reader
description: >
  Report the last RFID card scan from the RC522 reader. Use when the user asks
  who scanned, when was the last scan, what was the last RFID read, or who just tapped.
  The reader runs on the Pi host; this skill reads the shared last-scan state file.
metadata:
  openclaw:
    emoji: "💳"
    requires:
      bins: ["bash", "python3"]
---

# RFID Reader — last scan only (read from host-written state)

The RFID hardware is read by a **host daemon** on the Pi (not inside the container). The daemon writes the latest scan to a shared file. This skill reports that state.

## When to use

- "Who scanned?" / "Who just tapped?"
- "Last RFID scan" / "What was the last card?"
- "Did anyone scan?" / "RFID status"

## Pipeline (execute in order)

### STEP 1 — Read last scan state

Read the file written by the host daemon:

```
read: /home/openclaw/.openclaw/workspace/rfid/last_scan.json
```

If the file does not exist or is empty, go to Step 2 with no data.

### STEP 2 — Respond

- **If you have valid JSON** with `tag_id`, `timestamp_iso` (and optionally `uid_hex`): Reply with a short, human sentence: who/what was the last scan and when. Example: "Last scan was **abc123** at 14:32 UTC." Do not mention files, JSON, or the daemon.
- **If file missing or empty:** Reply that no recent scan is recorded. Do not mention internals (e.g. "the daemon hasn't written a file").

Optional: for a single-line summary you can exec the formatter script instead of parsing in-context:

```
exec: bash /home/openclaw/.openclaw/workspace/skills/rfid-reader/scripts/format-last-scan.sh
```

Use the script output as the basis for your reply. If the script exits non-zero or prints nothing, treat as no recent scan.

## Rules

- Never mention tool names, file paths, or "the daemon" in the user-facing reply.
- Scan notifications are also sent to Telegram by the host daemon; the user may already see "RFID scan: ..." there. This skill is for when they ask the agent directly.
