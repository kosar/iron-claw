---
name: piglow-signal
description: >
  Communicate agent status to the user via the PiGlow LED board on the Raspberry Pi.
  Use to show "working", "done", "problem", or "ready" without saying it in chat.
  Only applies when PiGlow is attached and the host PiGlow service is running.
metadata:
  openclaw:
    emoji: "💡"
    requires:
      bins: ["curl", "bash"]
---

# PiGlow signal — status via LED (never crash, silent if unavailable)

The PiGlow is a multi-colour LED board on the Pi. This skill lets the agent set its status **visually** so the user can see "I'm on it" or "Done" at a glance. All calls are **silent** and **never fail** the run: if the service or hardware is missing, nothing happens and the agent continues.

## When to use

- **Start of a task** (e.g. user asked for something that will take a moment): set **thinking** so the Pi shows blue.
- **Task completed successfully**: set **success** so the Pi shows a short green confirmation.
- **Task failed or error**: set **error** so the Pi shows red.
- **Warning / partial failure**: set **warning** (amber).
- **Need to draw attention** (e.g. reminder, alert): set **attention** (yellow double-flash).
- **Back to idle** (ready for next request): set **idle** (dim white) or **off**.
- **Open for business** (bot just started or user sent /reset): set **ready** — three green flashes then idle. Use for startup signal and when handling /reset.

Use this **in addition to** your normal reply. Do not mention "PiGlow" or "LED" in the user-facing message.

## Pipeline (execute in order)

### STEP 1 — When you start working on a request that will take more than a few seconds

Run once at the start of your work (optional but recommended):

```
exec: bash /home/ai_sandbox/.openclaw/workspace/skills/piglow-signal/scripts/signal.sh thinking
```

No need to check return value. Continue with your tools and skills as usual.

### STEP 2 — When you finish (success or failure)

Before or after sending your reply, set the outcome:

- **Success:**  
  `exec: bash /home/ai_sandbox/.openclaw/workspace/skills/piglow-signal/scripts/signal.sh success`
- **Error / failed:**  
  `exec: bash /home/ai_sandbox/.openclaw/workspace/skills/piglow-signal/scripts/signal.sh error`
- **Warning / partial:**  
  `exec: bash /home/ai_sandbox/.openclaw/workspace/skills/piglow-signal/scripts/signal.sh warning`

You can run this in the same run as your final message. Do not wait for or interpret the script output.

### STEP 3 — Optional: back to idle

When the conversation is idle and you are ready for the next request:

```
exec: bash /home/ai_sandbox/.openclaw/workspace/skills/piglow-signal/scripts/signal.sh idle
```

Or `off` to turn all LEDs off.

## Best-practice colour semantics (do not expose in chat)

| State      | Colour  | Meaning (UX)                          |
|-----------|---------|----------------------------------------|
| idle      | Dim white | Ready; low attention                  |
| thinking  | Blue    | Working / loading                      |
| success   | Green (brief) | Task completed successfully       |
| warning   | Orange  | Caution / partial issue                |
| error     | Red     | Failure / error                        |
| attention | Yellow (double-flash) | Needs user attention      |
| ready     | Green (triple flash → idle) | Bot up / open for business; use for startup and /reset |
| off       | Off     | LEDs off                               |

Keep signals **consistent**: same state = same meaning every time. Avoid rapid flashing; the service uses short, clear patterns.

## Rules

- **Never crash the agent:** The script always exits 0. If the PiGlow service or hardware is missing, the exec succeeds and does nothing.
- **Never mention PiGlow or LEDs** in the user-facing reply. The user sees the light; they do not need to hear "I set the LED to success."
- Use **thinking** when you start a multi-step or slow task; use **success** or **error** when you finish, so the user gets visual feedback even before reading the message.
- Optional: use **idle** when you are done and waiting for the next request, so the Pi shows "ready" instead of staying on the last state.

## Host setup (for the human)

The PiGlow service must run on the **Pi host** (not in the container), on port **18793**. Start it with:

```bash
python3 /path/to/agents/pibot/workspace/piglow/piglow_service.py
```

Or use a systemd unit. I2C must be enabled (e.g. `raspi-config` → Interface Options → I2C). If PiGlow is not attached or I2C is off, the service still runs and returns `piglow_available: false`; the skill continues to work and simply does not change any LEDs.
