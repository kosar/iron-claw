# Recreating a pibot-equivalent agent from the template

This repo does not ship a pre-made `pibot` directory. To get a Raspberry Pi–style agent (exec in container, PiGlow, PiFace, IR, RFID, camera, Telegram), you create an agent from the **template** and configure it. The template already includes the Pi-specific skills and support directories; you only need to configure and enable them.

## 1. Create the agent from template

From the repo root:

```bash
./scripts/create-agent.sh pibot-demo
```

This creates `agents/pibot-demo/` with a full copy of the template (including Pi skills and support dirs). Use any name you like instead of `pibot-demo`.

## 2. Set Pi-style deployment in agent.conf

Edit `agents/pibot-demo/agent.conf` and set:

- **EXEC_HOST=gateway** — Run exec inside the container (no Docker sandbox). Required on Pi.
- **HARDWARE_PROFILE=pi** — Enables Ollama LAN discovery, PiGlow URL injection, LIRC device wait, and post-start PiGlow “ready” signal. Omit or leave unset for non-Pi agents.

Example:

```conf
AGENT_NAME=pibot-demo
AGENT_PORT=18791
EXEC_HOST=gateway
HARDWARE_PROFILE=pi
AGENT_CONTAINER=pibot-demo_secure
AGENT_MEM_LIMIT=2g
AGENT_CPUS=1.5
AGENT_SHM_SIZE=128m
```

## 3. Secrets and .env

```bash
cp agents/pibot-demo/.env.example agents/pibot-demo/.env
```

Edit `.env` and set at least:

- `OPENCLAW_GATEWAY_TOKEN` (e.g. `openssl rand -hex 24`)
- `OPENCLAW_OWNER_DISPLAY_SECRET` (required by OpenClaw)
- `OPENAI_API_KEY` (or use Ollama-only; see template config)
- `TELEGRAM_BOT_TOKEN` (from @BotFather) if you use Telegram
- `OPENCLAW_HOOKS_TOKEN` (must differ from gateway token) if you use hooks (e.g. RFID notify)

## 4. Enable channels and skills in config

Edit `agents/pibot-demo/config/openclaw.json`:

- **Telegram:** Set `channels.telegram.enabled` to `true`, set `allowFrom` to your Telegram user ID (numeric). Get your ID from a helper bot or from Telegram.
- **Skills:** In `skills.entries`, enable the ones you need: `piglow-signal`, `piface-display`, `ir-blast`, `rfid-reader`, `camera-capture`, `image-gen`, `image-vision`, `send-email`, etc. Template defaults leave many disabled; turn on what you use.

Do **not** commit `.env` or add real tokens to the repo.

## 5. On the Raspberry Pi (hardware setup)

- Install Docker, build the image, and run as in [RASPBERRY-PI-RUNBOOK.md](RASPBERRY-PI-RUNBOOK.md). Use your agent name (e.g. `pibot-demo`) instead of `pibot` in all commands.
- For **PiGlow:** Run the PiGlow service on the host (e.g. port 18793); see runbook. `compose-up.sh` will inject the signal URL into the agent workspace when `HARDWARE_PROFILE=pi`.
- For **IR blaster:** Install udev rule and LIRC; use `docker-compose.override.yml` to pass `/dev/lirc0` into the container. See [docs/IR-DONGLE.md](IR-DONGLE.md).
- For **RFID:** Run the RFID daemon and notify bridge on the host; see [docs/RFID-RC522-PIBOT.md](RFID-RC522-PIBOT.md).
- For **camera:** USB camera on host; see [docs/CAMERA-CAPTURE-PIBOT.md](CAMERA-CAPTURE-PIBOT.md).

## 6. Start the agent

```bash
./scripts/compose-up.sh pibot-demo -d
./scripts/test-gateway-http.sh pibot-demo
```

If the gateway returns JSON, the agent is up. Add your Telegram user ID to `allowFrom` in config if you have not already, then message your bot.

## Verification (proof that template is sufficient)

To confirm a pibot-equivalent can be recreated without any legacy agent directory:

1. Run steps 1–4 above (create-agent, agent.conf with EXEC_HOST and HARDWARE_PROFILE=pi, .env, enable Telegram + skills in openclaw.json).
2. Run step 6. The gateway should start; `test-gateway-http.sh` should return JSON.
3. On a Pi with hardware, run the runbook and optional host services; then PiGlow, IR, RFID, or camera can be tested as described in the linked docs.

All Pi-specific skills and support files (piglow-signal, piface-display, ir-blast, rfid-reader, camera-capture, audio, rfid, piglow, piface, ir-codes, etc.) live in the **template**; creating an agent from the template gives you everything you need to run a pibot-style agent.
