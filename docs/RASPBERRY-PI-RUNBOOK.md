# Raspberry Pi Runbook: Pibot from Scratch to Running

This document is the full retrospective and checklist for getting ironclaw’s **pibot** agent running on a **clean Raspberry Pi** (ARM64, e.g. Pi 4/5). Use it to repeat the process on a new Pi or after a fresh OS install.

---

## Prerequisites

- Raspberry Pi with 64-bit OS (e.g. Raspberry Pi OS), network (Wi‑Fi or Ethernet), and SSH or console access.
- Ironclaw repo cloned (e.g. `~/ironclaw`). No Docker, no prior setup.
- Your pibot Telegram bot token and API keys (OpenAI, Moonshot, etc.) for `.env`.

---

## 1. Install Docker and Docker Compose

On the Pi (Debian/Raspberry Pi OS):

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
```

Then **log out and log back in** (or reboot) so your user is in the `docker` group. Otherwise you must use `sudo` for every `docker` command.

Check:

```bash
docker --version
docker compose version
```

---

## 2. Ensure Image Tag Matches Template (YML)

The compose template specifies which image to run. The image you build is tagged in the next step.

- **Template file:** `scripts/docker-compose.yml.tmpl`
- **Line:** `image: ironclaw:2.0` (or `ironclaw:2.1` in some branches)

**Rule:** The `image:` value must match the tag you use when building. We use **`ironclaw:2.0`** in this runbook.

If your template has `image: ironclaw:2.1` but you run `docker build -t ironclaw:2.0 .`, the container will fail to start (“unable to get image 'ironclaw:2.1'”). So either:

- **Option A:** Build with the same tag as the template, e.g. `docker build -t ironclaw:2.1 .`, or  
- **Option B:** Edit `scripts/docker-compose.yml.tmpl` and set `image: ironclaw:2.0` (or whatever tag you build).

**Why this happens:** The repo may have been used on another machine (e.g. Mac) with a different image tag (2.1). On the Pi we built and tagged as 2.0; the template was still 2.1, so we changed the template to 2.0. For repeatability, decide one tag (e.g. 2.0) and keep the template and `docker build -t` in sync.

---

## 3. Build the Ironclaw Image

From the **repo root** (e.g. `~/ironclaw`):

```bash
cd ~/ironclaw
docker build -t ironclaw:2.0 .
```

Use the same tag as in the template (e.g. `ironclaw:2.0`). The first build can take 10–15 minutes on a Pi (Node, Chromium, OpenClaw npm install). When it finishes, you should see `Successfully tagged ironclaw:2.0`.

---

## 4. Configure Pibot: `.env`

Secrets and env vars are in the agent’s `.env` file. The container gets them via compose `env_file`.

- **Path:** `agents/pibot/.env`
- If missing: `cp agents/pibot/.env.example agents/pibot/.env`, then edit.

**Required for pibot (cloud-only, no Ollama on Pi):**

| Variable | Purpose |
|----------|---------|
| `OPENCLAW_GATEWAY_TOKEN` | Gateway HTTP/WS auth. Generate e.g. `openssl rand -hex 24` |
| `OPENCLAW_OWNER_DISPLAY_SECRET` | Required by OpenClaw; set any secret value |
| `OPENAI_API_KEY` | OpenAI API key |
| `MOONSHOT_API_KEY` | Moonshot (Kimi) API key |
| `TELEGRAM_BOT_TOKEN` | From @BotFather for your pibot bot |

Optional: `BRAVE_API_KEY` (web search), `SMTP_FROM_EMAIL`, `GMAIL_APP_PASSWORD` (email).  
Do not commit `.env`; it is gitignored.

---

## 5. Gateway Control UI When Using `bind: "lan"` (JSON)

Pibot (and the template) use `"bind": "lan"` so the gateway listens on all interfaces inside the container. That is required for Docker port mapping and for Telegram/webhooks to reach the gateway.

**Newer OpenClaw** requires an explicit Control UI setting when the gateway is bound to a non-loopback address. Without it, the gateway **refuses to start** and logs:

```text
Gateway failed to start: Error: non-loopback Control UI requires gateway.controlUi.allowedOrigins
(set explicit origins), or set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback=true
```

**Fix (preferred — secure):** Use explicit `allowedOrigins` only. In the agent’s gateway config (e.g. `agents/pibot/config/openclaw.json`), inside the `"gateway"` object, add:

```json
"controlUi": {
  "allowedOrigins": [
    "http://localhost:18791",
    "http://127.0.0.1:18791"
  ]
}
```

(Use your agent’s port instead of 18791.) So the gateway block looks like:

```json
"gateway": {
  "port": 18791,
  "mode": "local",
  "bind": "lan",
  "controlUi": {
    "allowedOrigins": [
      "http://localhost:18791",
      "http://127.0.0.1:18791"
    ]
  },
  "auth": { "mode": "token", "token": "${OPENCLAW_GATEWAY_TOKEN}" },
  ...
}
```

**Why bind is "lan":** With `bind: "lan"`, the gateway listens on all interfaces inside the container so Docker port mapping works. With `bind: "loopback"`, OpenClaw would bind only to 127.0.0.1 inside the container and Docker could not forward host traffic — you’d get “Empty reply from server.” So we keep `bind: "lan"` and satisfy the non-loopback requirement with explicit **allowedOrigins** (no `dangerouslyAllowHostHeaderOriginFallback`). To access the Control UI from another machine on the LAN, add that origin (e.g. `http://192.168.1.5:18791`) to `allowedOrigins`. The setup script sets these for you when needed.

---

## 6. Start the Pibot Container

From repo root, with Docker available (after re-login or using `sudo`):

```bash
cd ~/ironclaw
./scripts/compose-up.sh pibot -d
```

If you see “permission denied” on the Docker socket, either:

- Re-login after step 1 so your user is in the `docker` group, or  
- Run: `sudo ./scripts/compose-up.sh pibot -d`

The script syncs `config/` → `config-runtime/`, then runs `docker compose up -d` for pibot. Container name: `pibot_secure`, port **18791** (host → container).

Check:

```bash
docker ps
```

You should see `pibot_secure` (healthy after the healthcheck passes). If the gateway had been failing (e.g. missing `controlUi`), do a full restart so it reads the updated config:

```bash
cd ~/ironclaw/agents/pibot
docker compose -p pibot down
cd ~/ironclaw
./scripts/compose-up.sh pibot -d
```

---

## 7. Verify the Gateway

```bash
./scripts/test-gateway-http.sh pibot
```

You should get a JSON response with something like `"content":"pibot is working."`. If you get “Connection reset by peer,” the gateway is not starting—check container logs (step 8) and confirm the JSON `controlUi` and `.env` are correct.

**After any gateway or openclaw.json change**, verify all bridges so one fix doesn't hide another:
1. Gateway: `./scripts/test-gateway-http.sh pibot` → JSON response.
2. Channels: Send a test Telegram message; agent must reply.
3. PiGlow (if used): Host service must be running (`curl -s http://127.0.0.1:18793/health` on host). If the agent still can't reach it (e.g. `host.docker.internal` issues on your Pi), set in `agents/pibot/.env`: `PIGLOW_SIGNAL_URL=http://<host-ip>:18793/signal` then restart.

---

## 8. Enable Start at Boot (Systemd)

So pibot starts after reboot:

```bash
sudo cp ~/ironclaw/scripts/systemd/ironclaw-pibot.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable ironclaw-pibot.service
```

The unit runs `scripts/start-pibot-at-boot.sh`, which waits for a host IP then runs `compose-up.sh pibot -d`.  
`compose-up.sh` then waits up to 30s for the LIRC device (if you use the IR override) to exist and be readable before starting the container, so IR blasting works after reboot without you doing anything. Ensure the udev rule for `/dev/lirc*` is installed (see docs/IR-DONGLE.md §5a) and the override uses the correct device (e.g. `/dev/lirc0`).

If your repo is **not** at `/home/kosar/ironclaw`, edit the service file (or create a copy) and set `WorkingDirectory` and `ExecStartPre`/`ExecStart` paths to your repo (e.g. `/home/pi/ironclaw`). The comment in the service file mentions changing User/Group to `pi` and paths to `/home/pi/ironclaw` for default Raspberry Pi OS.

---

## 9. Install `jq` for Log Monitoring

The log watcher script parses JSON lines with `jq`. If `jq` is not installed, the script exits on the first line and you see no log output.

```bash
sudo apt-get update
sudo apt-get install -y jq
```

Check: `jq --version`.  
The script `scripts/watch-logs.sh` now checks for `jq` at startup and prints a clear error if it’s missing.

---

## 10. Optional: Watch Logs

```bash
./scripts/watch-logs.sh pibot
```

You should see live lines (RUN, LLM, DONE, etc.) when there’s traffic. Use your pibot Telegram bot to generate traffic. Exit with Ctrl+C.

---

## 11. Host Dashboard (optional)

A web dashboard runs on the Pi and shows agents, containers, host bridges (capture, PiGlow, PiFace), gateway health, recent logs, failure summary, and usage. No SSH needed.

**Start the dashboard once:**

```bash
./scripts/start-dashboard.sh
```

Then open **http://\<pi-ip\>:18795** in a browser (e.g. `http://192.168.1.10:18795`).

**Start dashboard at boot (systemd):**

```bash
sudo cp ~/ironclaw/scripts/systemd/ironclaw-dashboard.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable ironclaw-dashboard.service
```

If your repo or user differs (e.g. `/home/pi/ironclaw`, user `pi`), edit the service file paths and User/Group before copying.

**Open dashboard in browser on desktop login (optional):**

So the dashboard is the first page when you log into the Pi desktop:

```bash
mkdir -p ~/.config/autostart
cp ~/ironclaw/dashboard/autostart/ironclaw-dashboard.desktop.example ~/.config/autostart/ironclaw-dashboard.desktop
```

Edit `~/.config/autostart/ironclaw-dashboard.desktop` and set `Exec=` to the full path of `dashboard/open-dashboard-browser.sh` (e.g. `/home/pi/ironclaw/dashboard/open-dashboard-browser.sh`). On login, the script waits for the dashboard server to respond, then opens the default browser to the dashboard. If the dashboard service is not enabled, the script exits quietly.

---

## Summary Checklist (Repeatable)

| # | Step | Command / Action |
|---|------|-------------------|
| 1 | Install Docker | `curl -fsSL https://get.docker.com \| sh` then `sudo usermod -aG docker $USER`; re-login |
| 2 | Image tag vs template | Ensure `scripts/docker-compose.yml.tmpl` has `image: ironclaw:2.0` (or the tag you build) |
| 3 | Build image | `cd ~/ironclaw && docker build -t ironclaw:2.0 .` |
| 4 | Configure .env | Edit `agents/pibot/.env`: gateway token, owner secret, OpenAI, Moonshot, Telegram token |
| 5 | Gateway Control UI | In `agents/pibot/config/openclaw.json`, gateway section: add `"controlUi": { "allowedOrigins": ["http://localhost:PORT", "http://127.0.0.1:PORT"] }` with your agent port (template has it for new agents). Do not use dangerouslyAllowHostHeaderOriginFallback. |
| 6 | Start container | `./scripts/compose-up.sh pibot -d` (or `sudo ...` if not in docker group) |
| 7 | Verify | `./scripts/test-gateway-http.sh pibot` → JSON with “pibot is working.” |
| 8 | Start at boot | `sudo cp scripts/systemd/ironclaw-pibot.service /etc/systemd/system/` then `daemon-reload` and `enable` |
| 9 | jq for logs | `sudo apt-get install -y jq` (install before first compose-up; script needs it for port injection) |
| 10 | Watch logs (optional) | `./scripts/watch-logs.sh pibot` |
| 11 | Host dashboard (optional) | `./scripts/start-dashboard.sh` → open http://\<pi-ip\>:18795 ; or install `scripts/systemd/ironclaw-dashboard.service` and enable for boot |
| 12 | Dashboard on login (optional) | Copy `dashboard/autostart/ironclaw-dashboard.desktop.example` to `~/.config/autostart/` and set Exec path |

**Physical output (PiGlow / PiFace) — choose per device:** If **this Pi has PiGlow and/or PiFace**, do **not** create `agents/pibot/workspace/HARDWARE.md`; the agent will run signal/display every run. If **this Pi is headless or has no PiGlow/PiFace**, create the flag file so the agent skips those execs: `cp agents/pibot/workspace/HARDWARE.md.example agents/pibot/workspace/HARDWARE.md` (file is gitignored; each device is independent).

**PiGlow (optional, when hardware is present):** Enable I2C (raspi-config), run `./scripts/piglow-test.sh` (use `--install` if sn3218 missing). Start host service: `python3 agents/pibot/workspace/piglow/piglow_service.py`, or copy `scripts/systemd/piglow-service.user.service.example` to `~/.config/systemd/user/piglow-service.service`, then `systemctl --user enable --start piglow-service.service`. For user service at boot without login: `loginctl enable-linger $USER`. **For reliable activity indication on every run (thinking when a request starts, success/error when it completes):** run the log bridge on the host: `./scripts/piglow-log-bridge.sh pibot` (or add it to a user systemd unit). It tails the agent’s app log and drives PiGlow on `embedded run start` and `embedded run done`, so the LED reflects activity even if the agent doesn’t call the skill.

**Internal learning feedback (owner-only):** `compose-up.sh pibot -d` now auto-starts `scripts/learning-log-bridge.sh pibot` unless disabled with `IRONCLAW_DISABLE_LEARNING_BRIDGE=1`. The bridge evaluates each completed run (`embedded run done`) and writes feedback under `agents/pibot/logs/learning/` (including `quality-timeseries.jsonl` for historical trend detection and feedback-uptake tracking). To run under user systemd, copy `scripts/systemd/learning-log-bridge.user.service.example` to `~/.config/systemd/user/learning-log-bridge.service`, then `systemctl --user daemon-reload && systemctl --user enable --start learning-log-bridge.service`. Configure optional owner delivery in `agents/pibot/.env`: `LEARNING_FEEDBACK_EMAIL`, `LEARNING_FEEDBACK_EMAIL_MODE` (`immediate|digest|off`), digest knobs `LEARNING_FEEDBACK_DIGEST_MIN_RUNS` / `LEARNING_FEEDBACK_DIGEST_MINUTES`, and existing SMTP vars.

**Logs dir ownership:** When running `compose-up.sh` with `sudo` (e.g. on Pi), the script now chowns `agents/pibot/logs` to `1000:1000` so OpenClaw’s temp-dir check passes. If the container restarts with “Unsafe fallback OpenClaw temp dir”, ensure logs is owned by the container user: `sudo chown -R 1000:1000 agents/pibot/logs`.

---

## The Two Config Changes (Why They Were Needed)

### 1. YML: `scripts/docker-compose.yml.tmpl` — `image: ironclaw:2.1` → `image: ironclaw:2.0`

- **What:** The template tells compose which image name:tag to run. We built the image as `ironclaw:2.0` on the Pi; the template still said `ironclaw:2.1`.
- **Effect:** Compose tried to pull/use `ironclaw:2.1`, which didn’t exist on the Pi, so the container failed to start.
- **Fix:** Use one consistent tag. Either build as 2.1 or set the template to 2.0. We set the template to `ironclaw:2.0` to match the build.
- **Going forward:** When you run `docker build -t ironclaw:X.Y .`, ensure the template’s `image:` is `ironclaw:X.Y`.

### 2. JSON: `agents/pibot/config/openclaw.json` — add `controlUi`

- **What:** OpenClaw (recent versions) require an explicit Control UI setting when the gateway is bound to a non-loopback address (`bind: "lan"`).
- **Effect:** Without it, the gateway process exits at startup with the “non-loopback Control UI requires…” error. The container stays up but the gateway never listens, so you get “Connection reset by peer” or no response.
- **Fix:** Add `"controlUi": { "allowedOrigins": ["http://localhost:PORT", "http://127.0.0.1:PORT"] }` inside the `gateway` object (use your agent’s port). The template has this for new agents. Do not use `dangerouslyAllowHostHeaderOriginFallback`.
- **Going forward:** Any agent using `bind: "lan"` (e.g. in Docker or on a LAN IP) should have explicit `allowedOrigins` in its gateway config; the template includes it by default.

---

## If You’re Doing This “Again and Again”

- **Same Pi, re-image or re-setup:** Follow the checklist 1–10; the repo already has the template and pibot JSON fixes.
- **New Pi, same repo (e.g. clone/pull):** Same checklist. If the template is ever reverted or you use an older branch, re-apply step 2 (image tag) and step 5 (controlUi in gateway) as needed.
- **Different user/home (e.g. `pi` instead of `kosar`):** Update paths and User/Group in `scripts/systemd/ironclaw-pibot.service` (and in the service file comment) so the unit points to your repo and user.

This runbook is the single place for the full, start-to-finish process and the explanation of the two config changes.
