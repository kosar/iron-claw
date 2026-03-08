---
name: audio-capture
description: >
  Record audio from the Pi's USB microphone or play WAV files through the Pi's speaker.
  The audio subsystem runs on the host (audio bridge on port 18796); this skill triggers
  record/play from inside the container. Use for "record the mic", "play a sound", or
  when the user wants to leave a voice note (e.g. after an RFID scan with voice announce).
metadata:
  openclaw:
    emoji: "🎤"
    requires:
      bins: ["curl", "bash", "python3"]
---

# Audio capture — record from mic, play WAV (host bridge)

The microphone (and playback) are on the **Pi host**. The audio bridge service listens on port **18796** and handles record/play. This skill triggers those actions so the agent can record the user or play sounds.

## When to use

- "Record the microphone" / "Record me for N seconds" / "Start recording"
- "Play a sound" / "Play the latch tone" (e.g. `play.sh rfid/scan_sound.wav`)
- After an RFID scan with **voice announce** enabled: the latest recording is at `workspace/audio/last_record.wav`; you can reference it or (if you have transcription) include what the user said in the reply.

## Pipeline

### Record N seconds

Run from the workspace (container):

```
exec: bash /home/openclaw/.openclaw/workspace/skills/audio-capture/scripts/record.sh [seconds]
```

Default 10 seconds; max 60. The bridge writes to `workspace/audio/last_record.wav` (overwritten each time). On success the script prints `OK: workspace/audio/last_record.wav`. On failure it prints `RECORD_FAILED: <reason>` and exits non-zero.

### Play a WAV file

Path is relative to workspace (e.g. `rfid/scan_sound.wav`, `audio/prompt_announce.wav`):

```
exec: bash /home/openclaw/.openclaw/workspace/skills/audio-capture/scripts/play.sh <path>
```

Example: `play.sh rfid/scan_sound.wav` plays the two-tone latch.

## Rules

- Do not mention the bridge, port, or host.docker.internal in the user-facing reply.
- If record or play fails, say the microphone or speaker isn't available right now.
- The audio bridge must be running on the Pi host (see TOOLS.md / docs). If the skill fails, the user may need to start it.
