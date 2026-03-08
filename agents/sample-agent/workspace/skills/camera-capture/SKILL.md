---
name: camera-capture
description: >
  Take a still photo from the USB camera connected to the Pi. Use when the user
  asks to take a photo, snap a picture, capture from the camera, or get an image
  from the webcam. The camera runs on the Pi host; this skill triggers the host
  capture service and then sends the image to Telegram.
metadata:
  openclaw:
    emoji: "📷"
    requires:
      bins: ["curl", "bash", "python3"]
---

# Camera capture — take a photo from the USB camera

The camera hardware is on the **Pi host**. A small HTTP service on the host captures one frame and writes it to the shared workspace. This skill triggers that capture and sends the image to Telegram.

## When to use

- "Take a photo" / "Snap a picture"
- "Capture from the camera" / "Photo from the webcam"
- "Take a still" / "Get an image from the USB camera"

## Pipeline (execute in order)

### STEP 1 — Capture and send (single exec, mandatory)

Run the script that triggers the host capture and sends the image. You MUST use this single command so the photo is actually sent to Telegram:

```
exec: bash /home/openclaw/.openclaw/workspace/skills/camera-capture/scripts/capture-and-send.sh
```

If the exec returns CAPTURE_FAILED or NO_IMAGE or exits non-zero, go to Step 2 with failure. If it succeeds (you see "Sent via Telegram" or similar in the output), go to Step 2 with success.

### STEP 2 — Reply

- **Success:** Confirm briefly that you sent the photo (e.g. "Done, sent the photo to this chat."). Do not mention the script, service, or file paths.
- **Failure:** Say the camera isn't available right now. Do not expose internals.

## Rules

- Never mention the capture service, host.docker.internal, or file paths in the user-facing reply.
- The capture service must be running on the Pi host (see docs). If the skill fails, the user may need to start it.
