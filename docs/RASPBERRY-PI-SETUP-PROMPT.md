# Prompt: Set Up a Second Raspberry Pi Like My Current One (IronClaw pibot)

**Use this in a new Cursor session after you SSH into the new Raspberry Pi.** Paste the entire section below into the chat so the assistant can replicate your existing setup without changing the current Pi.

---

## Instructions for the AI assistant

I have a Raspberry Pi that runs the **ironclaw-core** project with a single agent called **pibot**. The Docker container comes up correctly and I want to set up **another Raspberry Pi** with the same setup. I will SSH into the new Pi and open this project (or clone the repo there). Please help me replicate the setup by doing the following.

### 1. Understand the reference setup (do not change it)

On the **existing** Pi the setup is:

- **Repo location:** `/home/kosar/ironclaw` (user `kosar`). If the new Pi uses default Raspberry Pi OS with user `pi`, use `/home/pi/ironclaw` and adjust any paths below accordingly.
- **Single agent:** `pibot` only (no ironclaw-bot or stylista on the Pi).
- **Agent config:** `agents/pibot/agent.conf` — port **18791**, **2g** RAM, **1.5** CPUs, **128m** shm (Pi-friendly).
- **Docker image:** `ironclaw:2.1` — built **on the Pi** for ARM (no pre-built image). From repo root:  
  `docker build -t ironclaw:2.1 .`
- **Secrets:** `agents/pibot/.env` — required: `OPENCLAW_GATEWAY_TOKEN`, `OPENCLAW_OWNER_DISPLAY_SECRET`, `OPENAI_API_KEY`, and at least one of `OPENAI_API_KEY` or `MOONSHOT_API_KEY`. For Telegram: `TELEGRAM_BOT_TOKEN`. Optional: `BRAVE_API_KEY`, `SMTP_FROM_EMAIL`, `GMAIL_APP_PASSWORD`. Copy from `agents/pibot/.env.example` and I will fill in real values.
- **Start command:** `./scripts/compose-up.sh pibot -d` (run from repo root).
- **Boot at startup:** systemd unit `scripts/systemd/ironclaw-pibot.service`:
  - Install: `sudo cp scripts/systemd/ironclaw-pibot.service /etc/systemd/system/`
  - If the new Pi user is `pi` (not `kosar`), edit the unit: set `User=pi`, `Group=pi`, and replace `/home/kosar/ironclaw` with `/home/pi/ironclaw` in all paths.
  - Then: `sudo systemctl daemon-reload && sudo systemctl enable ironclaw-pibot.service`
  - The unit runs `scripts/start-pibot-at-boot.sh`, which waits for a host IP (e.g. Wi‑Fi) then runs `compose-up.sh pibot -d`.

### 2. What to do on the new Pi

1. **Prerequisites**
   - Docker and Docker Compose installed (and user in `docker` group so you can run `docker` without sudo).
   - Git (to clone the repo if not already present).

2. **Repo**
   - Either clone the ironclaw repo to the chosen path (e.g. `/home/pi/ironclaw` or `/home/kosar/ironclaw`) or confirm the path if I already cloned it.

3. **Build the image**
   - From repo root: `docker build -t ironclaw:2.1 .`  
   - The compose template uses `image: ironclaw:2.1`; no other image tag is needed for this agent.

4. **Agent pibot**
   - Ensure `agents/pibot/` exists (it’s in the repo). Do **not** remove or overwrite `agent.conf` (it’s already Pi-friendly).
   - Create `agents/pibot/.env`: copy from `agents/pibot/.env.example`. Tell me exactly which variables I must set (e.g. OPENCLAW_GATEWAY_TOKEN, OPENCLAW_OWNER_DISPLAY_SECRET, OPENAI_API_KEY or MOONSHOT_API_KEY, TELEGRAM_BOT_TOKEN if I use Telegram). Remind me never to commit `.env` or add it to git.

5. **First run**
   - From repo root: `./scripts/compose-up.sh pibot -d`
   - Verify container is up: `docker ps` (expect `pibot_secure` on port 18791).
   - Optional: run `./scripts/test-gateway-http.sh pibot` if the script exists and curl is available.

6. **Optional: start at boot**
   - Install and enable `scripts/systemd/ironclaw-pibot.service` as above, adjusting User/Group and paths if the new Pi uses user `pi` and `/home/pi/ironclaw`.

7. **Optional: Telegram**
   - If I want this Pi’s pibot on Telegram: create a bot with @BotFather, set `TELEGRAM_BOT_TOKEN` in `.env`, put my Telegram user ID in `agents/pibot/config/openclaw.json` under `channels.telegram.allowFrom`, then restart with `./scripts/compose-up.sh pibot -d`.

8. **Optional: LAN Ollama (image generation)**
   - If I have an Ollama server on the LAN (e.g. another machine), the pibot image-gen skill can use it; the compose setup injects `SCAN_SUBNET` from the host IP. No change needed unless my LAN subnet differs; then we can adjust if necessary.

9. **Device configuration: PiGlow / PiFace (physical output)**
   - If **this new Pi has PiGlow and/or PiFace** (LEDs, LCD), do **not** create `agents/pibot/workspace/HARDWARE.md` — the agent will run signal/display every run. Set up the host bridge services per `docs/RASPBERRY-PI-RUNBOOK.md`.
   - If **this new Pi is headless or has no PiGlow/PiFace**, create the flag file so the agent skips those execs: `cp agents/pibot/workspace/HARDWARE.md.example agents/pibot/workspace/HARDWARE.md`. The file is gitignored; it is per-device and not in the repo.

Do not modify the **existing** Pi or the main repo layout; only guide me through steps on the **new** Pi. If anything is missing (e.g. no `.env.example`), tell me what to create and what to put in it. Prefer using the project’s existing scripts and docs (e.g. `CLAUDE.md`, `README.md`, `agents/pibot/workspace/TODO.md`) so the setup matches the first Pi.

---

*End of prompt. Paste everything from "Instructions for the AI assistant" through "End of prompt" into a new Cursor chat on the new Raspberry Pi.*
