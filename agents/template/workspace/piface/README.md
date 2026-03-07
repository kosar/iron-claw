# PiFace display bridge (pibot)

HTTP service that runs on the Raspberry Pi host and drives the PiFace CAD 2×16 LCD. The pibot container sends display updates via `curl` to `host.docker.internal:18794`.

## Prerequisites

- PiFace Control and Display (CAD) board attached to the Pi.
- **SPI enabled:** `sudo raspi-config` → Interface Options → SPI → Enable.
- **pifacecad** Python module. The package `python3-pifacecad` is often **not** in Raspberry Pi OS repos; install from source (clone to `/tmp` so `sudo` install doesn’t leave root-owned files in your repo):

  ```bash
  sudo apt-get update
  sudo apt-get install -y python3-dev python3-setuptools
  cd /tmp
  git clone https://github.com/piface/pifacecad
  cd pifacecad
  sudo python3 setup.py install
  cd /
  sudo rm -rf /tmp/pifacecad
  ```

  If you prefer to try apt first (some images have it): `sudo apt-get install python3-pifacecad`.  
  If you get `ModuleNotFoundError: No module named 'pifacecommon'` or `No module named 'lirc'`, install deps:  
  `sudo pip3 install --break-system-packages pifacecommon lirc`  
  On **Pi 5 / newer kernels**, GPIO interrupt setup can fail; the bridge no-ops that path so the **LCD still works**.

## Run the bridge

From the ironclaw repo (or wherever this workspace is):

```bash
python3 agents/pibot/workspace/piface/piface_bridge.py
```

Or from this directory:

```bash
cd agents/pibot/workspace/piface
python3 piface_bridge.py
```

- Listens on **0.0.0.0:18794** (override with `PIFACE_DISPLAY_PORT`).
- **Endpoints:** `GET /display?l1=...&l2=...&backlight=1`, `GET /admin_stats?user=...&action=...&bal=...`, `GET /health`.
- If pifacecad is not installed or the hardware is missing, the server still runs and returns 200 so the container’s scripts don’t fail; `/health` reports `piface_available: false`.

## Log bridge (recommended — display updates even when the agent skips the skill)

So the PiFace shows **THINKING...** / **DONE** on every Telegram run even if the model doesn’t call the piface-display skill, run the log bridge as a **user systemd service** (runs in the background and survives reboot):

```bash
# One-time setup: copy the example, fix paths if your repo is elsewhere, enable and start
mkdir -p ~/.config/systemd/user
cp /home/kosar/ironclaw/scripts/systemd/piface-log-bridge.user.service.example ~/.config/systemd/user/piface-log-bridge.service
# If ironclaw is elsewhere, edit WorkingDirectory and ExecStart in the file
systemctl --user daemon-reload
systemctl --user enable --now piface-log-bridge.service
# So it runs at boot without login:
loginctl enable-linger $USER
```

Logs: `journalctl --user -u piface-log-bridge.service -f`. Requires **jq** and the PiFace bridge (port 18794) to be running.  
After each Telegram run it shows DONE then **reverts to the system message** (e.g. "System" / "Ready") after 60 seconds. Override with `PIFACE_REVERT_SECS`, `PIFACE_IDLE_L1`, `PIFACE_IDLE_L2` (e.g. in the systemd unit `Environment=`).

### Host-side system message (IP, memory)

**"PiBot: ONLINE", IP, and memory** can come from two places:

1. **Container (heartbeat)** — The agent’s first heartbeat runs `startup.sh "PiBot: ONLINE" "Mem:OK Skills:12"` and later `admin.sh "System" "Heartbeat OK" "Active"`. That runs *inside* the OpenClaw container and curls the bridge. If the container isn’t up or the model doesn’t run those scripts, you won’t see those updates.

2. **Host (recommended for IP/memory)** — A **host-side** script runs on the Pi and does not depend on the container:
   - **At boot:** `scripts/start-pibot-at-boot.sh` calls `scripts/piface-system-display.sh` after starting pibot, so the display gets "PiBot &lt;IP&gt;" and "Mem: XG" (or "Ready") once the host has an IP.
   - **Timer (sweep back to system):** Install the user timer so the display is **periodically overwritten** with host IP + memory. When the timer fires (e.g. every 5 min), it sweeps whatever is on the PiFace (agent summary, DONE, etc.) and puts back the system view — so the display stays clean. Install:
     - Copy `scripts/systemd/piface-system-display.user.service.example` → `~/.config/systemd/user/piface-system-display.service`
     - Copy `scripts/systemd/piface-system-display.user.timer.example` → `~/.config/systemd/user/piface-system-display.timer`
     - Fix paths in the service if the repo is not at `/home/kosar/ironclaw`
     - `systemctl --user daemon-reload && systemctl --user enable --now piface-system-display.timer`

### PiFace shows no updates (troubleshooting)

1. **Check bridge health**  
   `curl -s http://127.0.0.1:18794/health`  
   - If you see `"piface_available": false`, the HTTP bridge is running but the **LCD hardware is not detected**. The log bridge can send THINKING/DONE to the bridge, but the bridge cannot drive the display. Fix: enable SPI (`raspi-config` → Interface Options → SPI → Enable), ensure the PiFace CAD is connected, and install `pifacecad` (see Install above). Restart the bridge after fixing.
   - If the curl fails, the PiFace bridge service is not running: `sudo systemctl status piface-bridge.service`.

2. **Confirm the log bridge is firing**  
   The log bridge only reacts to **new** log lines (it runs `tail -f`). Send a **new** Telegram message to the bot, then:
   - Run the log bridge in debug mode (stop the user service first so you don’t have two tails):  
     `systemctl --user stop piface-log-bridge.service`  
     `PIFACE_LOG_BRIDGE_DEBUG=1 ./scripts/piface-log-bridge.sh pibot`  
   - When you send a Telegram message you should see lines like:  
     `PiFace log bridge: sending l1=THINKING... l2=Telegram` then `PiFace log bridge: sending l1=DONE l2=OK`.  
   - Restart the service when done: `systemctl --user start piface-log-bridge.service`.

## Run at boot (optional)

Example systemd user service (run on the Pi):

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/piface-bridge.service << 'EOF'
[Unit]
Description=PiFace display bridge for pibot
After=network.target

[Service]
Type=simple
WorkingDirectory=/home/pi/ironclaw
ExecStart=/usr/bin/python3 agents/pibot/workspace/piface/piface_bridge.py
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now piface-bridge.service
```

Adjust `WorkingDirectory` and the path in `ExecStart` to match your repo location. For the service to run at boot without login: `loginctl enable-linger $USER`.

## Test

On the Pi:

```bash
curl -s "http://127.0.0.1:18794/display?l1=Hello&l2=PiFace"
curl -s "http://127.0.0.1:18794/health"
```

## Troubleshooting

**“Address already in use” (port 18794)** — Another process is using the port (often a previous bridge or the systemd service). Free it:

```bash
# See what’s using 18794
sudo ss -tlnp | grep 18794
# or: sudo lsof -i :18794

# If you started the bridge with systemd:
systemctl --user stop piface-bridge.service

# Or kill by PID (replace 12345 with the PID from ss/lsof):
kill 12345
```

Then start the bridge again.

**Leftover root-owned `pifacecad` in your repo** — If you already ran the old install from inside the repo and got “Permission denied” on `rm`, remove the clone with sudo:

```bash
cd ~/ironclaw   # or your repo path
sudo rm -rf pifacecad
```
