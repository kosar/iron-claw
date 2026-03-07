# USB camera capture — pibot on Raspberry Pi

Take a still image from a USB camera connected to the Pi. The **capture service** runs on the host and writes the image to the shared workspace; the **camera-capture** skill triggers it and sends the image to Telegram.

---

## 1. Port

- **Default port:** **18792**
- **Override:** Set `CAPTURE_PORT` in the environment (e.g. in a systemd unit or before starting the script). The port is also defined in `agents/pibot/workspace/camera/capture_service.py` as `DEFAULT_PORT` (and in this doc) so you can change it in one place if needed.

---

## 2. Dependencies (Pi host)

- **ffmpeg** — capture from `/dev/video*` (V4L2).
  ```bash
  sudo apt install -y ffmpeg
  ```
- **Python 3** — stdlib only (no pip packages) for the capture service.

---

## 3. Running the capture service

The service must run on the **Pi host** (not in Docker). It listens on port 18792 and writes `latest.jpg` to `agents/pibot/workspace/camera/` (the container sees it as `workspace/camera/latest.jpg`).

### Manual (foreground)

```bash
cd ~/ironclaw/agents/pibot/workspace/camera
python3 capture_service.py
```

Or from repo root:

```bash
python3 ~/ironclaw/agents/pibot/workspace/camera/capture_service.py
```

Stop with Ctrl+C.

### Background (systemd user service)

```bash
mkdir -p ~/.config/systemd/user
cp ~/ironclaw/scripts/systemd/capture-service.user.service.example ~/.config/systemd/user/capture-service.service
# Edit paths if your repo or user differ
systemctl --user daemon-reload
systemctl --user enable capture-service.service
systemctl --user start capture-service.service
```

---

## 4. Agent skill

- **Skill name:** camera-capture  
- **When:** User says "take a photo", "snap a picture", "capture from the camera", etc.  
- **What it does:** Calls `http://host.docker.internal:18792/capture`, then sends `workspace/camera/latest.jpg` to Telegram via send-photo.sh. The last image is kept for debugging.

---

## 5. Brightness / contrast (dark images)

Captures use ffmpeg’s `eq` filter to brighten by default. You can override with env vars (e.g. in `.env` or the systemd unit):

- **CAMERA_BRIGHTNESS** — default `0.2` (range about -1.0 to 1.0; positive = brighter).
- **CAMERA_CONTRAST** — default `1.08` (1.0 = normal; slightly above 1 adds punch).

Example: `CAMERA_BRIGHTNESS=0.35` for a brighter image. Restart the capture service after changing.

---

## 6. Multiple cameras

The service uses the **first available** `/dev/video*` device. If more than one device is detected, it writes `workspace/camera/camera-knowledge.md` with the list so the agent (or you) can see that other devices exist for future use.

---

## 7. Test (send one photo to Telegram)

From the Pi host:

```bash
python3 ~/ironclaw/agents/pibot/workspace/camera/test_capture_telegram.py
```

Requires `TELEGRAM_BOT_TOKEN` in `agents/pibot/.env` and `channels.telegram.allowFrom` in config. Captures one frame and sends it to your Telegram chat.

---

## 8. Troubleshooting — agent can’t take a picture

If the agent says the camera isn’t available, run the diagnostic on the **Pi host**:

```bash
bash ~/ironclaw/agents/pibot/workspace/camera/diagnose_capture.sh
```

It checks: capture service listening on 18792, `/dev/video*` present and readable, ffmpeg installed, workspace writable, and a test capture. Fix any step it reports as FAIL.

**Common causes:**

| Symptom | Cause | Fix |
|--------|--------|-----|
| “CAPTURE_FAILED” / no response | Capture service not running | Start it on the host: `python3 …/camera/capture_service.py` or `systemctl --user start capture-service.service` |
| Service returns `ok: false`, error “no /dev/video* devices” | No USB camera or wrong interface | Plug in the camera; run `ls /dev/video*`; enable camera in Pi config if needed |
| Service returns error “ffmpeg not installed” | ffmpeg missing on host | `sudo apt install -y ffmpeg` |
| Service returns error “Permission denied” or device not readable | User can’t read `/dev/video0` | `sudo usermod -aG video $USER` then log out and back in (or reboot) |
| Service works from host but agent still fails | Container can’t reach host | Ensure Docker has `extra_hosts: host.docker.internal:host-gateway`. Test: `docker exec pibot_secure curl -sf http://host.docker.internal:18792/capture` |
| “NO_IMAGE” | Service said ok but file missing in container | Same workspace must be mounted in the container; check `workspace/camera/` exists and capture service writes to the same path the container sees |

**Quick checks on the host:**

- Is something listening? `ss -tlnp | grep 18792` or `curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18792/capture -X POST`
- Run the capture service in the foreground to see errors: `python3 agents/pibot/workspace/camera/capture_service.py` (then trigger a capture from the agent or `curl -X POST http://127.0.0.1:18792/capture`).
