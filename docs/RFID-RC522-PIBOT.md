# RFID RC522 reader — pibot on Raspberry Pi

This doc covers hardware wiring, Pi setup, running the RFID daemon, and how the agent skill uses it. For **what was built and how to maintain/extend it**, see [RFID-RC522-IMPLEMENTATION.md](RFID-RC522-IMPLEMENTATION.md).

---

## 1. Hardware

- **Reader:** RC522 (MFRC522), 13.56 MHz, SPI. **3.3 V only** (do not use 5 V).
- **Tags:** 13.56 MHz MIFARE (e.g. MIFARE Classic 1K).

### Wiring (RC522 → Raspberry Pi)

| RC522 Pin | Pi GPIO / Bus | Notes        |
|-----------|----------------|--------------|
| SDA       | GPIO 8 (CE0)   | SPI chip select |
| SCK       | GPIO 11        | SPI clock   |
| MOSI      | GPIO 10        | SPI MOSI    |
| MISO      | GPIO 9         | SPI MISO    |
| RST       | GPIO 25        | Reset       |
| GND       | Ground         |             |
| 3.3V      | 3.3V           | **Not 5V**  |

---

## 2. Pi setup (before running the daemon)

1. **Enable SPI**  
   `sudo raspi-config` → Interface Options → SPI → Enable. Reboot.  
   Check: `ls /dev/spidev0.0` should exist.

2. **System packages**  
   ```bash
   sudo apt install -y python3-pip python3-venv python3-dev python3-rpi.gpio
   ```

3. **Python deps for RFID (venv)**  
   The daemon expects a venv at `agents/pibot/workspace/rfid/.venv` so the system Python stays clean:
   ```bash
   cd ~/ironclaw/agents/pibot/workspace/rfid
   python3 -m venv .venv --system-site-packages
   .venv/bin/pip install mfrc522
   ```
   Run the daemon (or test) with `.venv/bin/python3 rfid_daemon.py` or use the systemd unit which points at this venv.

4. **Permissions**  
   SPI/GPIO usually need root or membership in `spi` and `gpio`. Add your user:  
   `sudo usermod -aG spi,gpio $USER`  
   then log out and back in. Or run the daemon with `sudo` (not recommended long-term).

---

## 3. Env and config (for the daemon)

- **TELEGRAM_BOT_TOKEN** — from `agents/pibot/.env` (same as pibot). Used to send a Telegram message on each scan.
- **OPENCLAW_HOOKS_TOKEN** — from `agents/pibot/.env`. Used to call the gateway’s `/hooks/agent` endpoint so the **agent** runs and its reply is **delivered to Telegram**. **Must be different from OPENCLAW_GATEWAY_TOKEN** (OpenClaw refuses to start if they match). Generate one: `openssl rand -hex 32`. For hooks to work, `hooks` must be enabled in `agents/pibot/config/openclaw.json` (see implementation doc).
- **Chat ID** — the daemon reads it from `agents/pibot/config/openclaw.json` → `channels.telegram.allowFrom` (first user ID). That’s your Telegram user ID; for DMs it’s the same as the chat ID. No env var needed.

---

## 4. Running the daemon

The daemon must run **on the Pi host**, not inside Docker. It writes `last_scan.json` into `agents/pibot/workspace/rfid/`, which is mounted into the container as `workspace/rfid/`.

### Manual (foreground)

From repo root (use the venv so mfrc522 is available):

```bash
~/ironclaw/agents/pibot/workspace/rfid/.venv/bin/python3 ~/ironclaw/agents/pibot/workspace/rfid/rfid_daemon.py
```

Or from the rfid dir:

```bash
cd ~/ironclaw/agents/pibot/workspace/rfid
.venv/bin/python3 rfid_daemon.py
```

Ensure `agents/pibot/.env` has `TELEGRAM_BOT_TOKEN`; chat ID is read from config. Stop with Ctrl+C.

### Background (systemd user service)

Example user unit so the daemon starts at login and survives logout (run as the same user that owns the repo). A copy-ready example is in the repo:

```bash
mkdir -p ~/.config/systemd/user
cp ~/ironclaw/scripts/systemd/rfid-daemon.user.service.example ~/.config/systemd/user/rfid-daemon.service
# Edit paths if your repo or user differ (e.g. /home/pi/ironclaw)
```

Or create `~/.config/systemd/user/rfid-daemon.service` manually:

```ini
[Unit]
Description=RC522 RFID daemon for pibot
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/home/kosar/ironclaw
EnvironmentFile=/home/kosar/ironclaw/agents/pibot/.env
ExecStart=/home/kosar/ironclaw/agents/pibot/workspace/rfid/.venv/bin/python3 /home/kosar/ironclaw/agents/pibot/workspace/rfid/rfid_daemon.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

Adjust paths if your repo or user differs. Then:

```bash
systemctl --user daemon-reload
systemctl --user enable rfid-daemon.service
systemctl --user start rfid-daemon.service
systemctl --user status rfid-daemon.service
```

Logs: `journalctl --user -u rfid-daemon.service -f`

### Optional: RFID notify bridge (fallback so the agent always gets scan events)

If the daemon’s immediate gateway call fails (e.g. gateway not ready), a **poll-based bridge** can notify the agent every 10 seconds when it sees a new scan:

```bash
mkdir -p ~/.config/systemd/user
cp ~/ironclaw/scripts/systemd/rfid-notify-bridge.user.service.example ~/.config/systemd/user/rfid-notify-bridge.service
cp ~/ironclaw/scripts/systemd/rfid-notify-bridge.user.timer.example ~/.config/systemd/user/rfid-notify-bridge.timer
# Edit paths in the .service if your repo or user differ (e.g. /home/pi/ironclaw)
systemctl --user daemon-reload
systemctl --user enable rfid-notify-bridge.timer
systemctl --user start rfid-notify-bridge.timer
```

The bridge uses system Python (no venv) and reads `agents/pibot/.env` for `OPENCLAW_HOOKS_TOKEN` (or `OPENCLAW_GATEWAY_TOKEN`). It runs every 10s and only calls `/hooks/agent` when `last_scan.json` is newer than the last notified timestamp.

---

## 5. Agent skill (container)

- **Skill name:** rfid-reader  
- **When:** User asks “who scanned?”, “last RFID scan?”, “what was the last card?”  
- **What it does:** Reads `workspace/rfid/last_scan.json` (written by the daemon) and replies with the last tag ID and time.  
- **Notification flow:** On each new scan the daemon (1) writes `last_scan.json`, (2) sends a Telegram message to the user, and (3) calls the OpenClaw gateway so the **agent** runs immediately and can process the event (e.g. acknowledge, run skills). Optional: run the **rfid-notify-bridge** timer so the agent is notified even if the daemon’s gateway call failed.

See [RFID-RC522-IMPLEMENTATION.md](RFID-RC522-IMPLEMENTATION.md) for file list and how to change or extend behavior.
