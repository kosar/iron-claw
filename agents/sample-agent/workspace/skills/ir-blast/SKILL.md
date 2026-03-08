---
name: ir-blast
description: >
  Replay learned IR button presses (e.g. fan power, fan speed) by remote name and button name.
  Use when the user wants to control an IR device (fan, TV, etc.) and buttons were previously
  learned with scripts/ir-learn.py on the Pi. Only applies when the IR dongle is available.
metadata:
  openclaw:
    emoji: "📡"
    requires:
      bins: ["python3", "ir-ctl"]
---

# IR Blast — replay learned remote buttons

The user can control IR devices (fan, TV, etc.) by name. Buttons are **learned once** on the Pi with `./scripts/ir-learn.py` (remote name + button names). This skill **replays** those stored IR codes when the user asks (e.g. "turn on the fan", "blast fan power").

## When to use

- "Turn on the fan" / "Turn off the fan" → emit **fanremote2** (or the learned remote name) button **power** (or **on** / **off** if that’s how they were named).
- "Set fan to speed 1" → emit the button the user learned for that (e.g. **speed_1**).
- "Send the power button for the fan" / "Blast fan power" → emit that remote’s power button.
- "What IR buttons do we have?" / "List learned remotes" → list remotes and buttons from the catalog (Step 1 below).

The USB IR blaster must be on the same machine; if the agent runs in Docker, pass the LIRC device through (e.g. docker-compose.override.yml with `devices: - /dev/lirc0:/dev/lirc0`). See docs/IR-DONGLE.md.

## Pipeline (execute in order)

### STEP 1 — List learned remotes (when user asks what’s available)

Run the list script to see remotes and buttons:

```
exec: python3 /home/openclaw/.openclaw/workspace/skills/ir-blast/scripts/list_remotes.py
```

Use the output to answer "what can I control?" and to choose the correct **remote** and **button** names for Step 2. If the script prints nothing or says no remotes, reply that no IR buttons have been learned yet and suggest running `./scripts/ir-learn.py` on the Pi.

### STEP 2 — Emit a button (when user asks to control the device)

Run the emit script with **remote name** and **button name** (exactly as in the catalog):

```
exec: python3 /home/openclaw/.openclaw/workspace/skills/ir-blast/scripts/emit.py <remote> <button>
```

Example: to send the power button for the fan remote:

```
exec: python3 /home/openclaw/.openclaw/workspace/skills/ir-blast/scripts/emit.py fanremote2 power
```

- **remote** and **button** must match the names used when learning (e.g. from REMOTES.md). Use lowercase with underscores (e.g. `fan_remote`, `speed_1`).
- If the script fails (e.g. "Button not found" or "ir-ctl failed"), reply that the IR command couldn’t be sent (dongle or device issue) and do not expose script paths or tool names.

### STEP 3 — Respond

- **Success:** Confirm briefly (e.g. "Done, sent the power signal" / "Fan power toggled."). Do not mention "IR", "blast", or "script".
- **No remotes learned:** Tell the user to run the learner on the Pi: `./scripts/ir-learn.py`, then point the remote and name each button.
- **Emit failed:** Say the command couldn’t be sent and suggest checking the dongle or trying again.

## Rules

- Never mention "ir-blast", "ir-ctl", "REMOTES.md", or file paths in the user-facing reply.
- If the user hasn’t specified which remote (e.g. "turn on the fan" but you have multiple remotes), prefer the one that matches the device they mentioned (e.g. fan_remote for "fan") or list options once and then use the one they choose.
- Learning is done **on the Pi** with the CLI script; the agent only **replays** already-learned buttons.
