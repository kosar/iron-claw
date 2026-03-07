# Contributing to IronClaw

Thanks for your interest. This doc gets you from clone to a running agent quickly and explains how to contribute safely.

## Quick start (about 10 minutes)

1. **Clone the repo**
   ```bash
   git clone <repo-url> ironclaw && cd ironclaw
   ```

2. **Prerequisites:** Docker, Docker Compose, and `jq`. On macOS: `brew install jq`. On Debian/Ubuntu: `apt install jq`.

3. **Optional: run the doctor** to check your environment:
   ```bash
   ./scripts/doctor.sh
   ```

4. **Build the image**
   ```bash
   docker build -t ironclaw:2.0 .
   ```

5. **Configure the sample agent**
   ```bash
   cp agents/sample-agent/.env.example agents/sample-agent/.env
   ```
   Edit `agents/sample-agent/.env` and set at least:
   - `OPENCLAW_GATEWAY_TOKEN` — e.g. `openssl rand -hex 24`
   - `OPENCLAW_OWNER_DISPLAY_SECRET` — required by OpenClaw; use any secret value
   - `OPENAI_API_KEY` — for cloud LLM (or configure Ollama-only in `config/openclaw.json`)

   Optional: `TELEGRAM_BOT_TOKEN` (from @BotFather). If you enable Telegram, add your numeric user ID to `allowFrom` in `agents/sample-agent/config/openclaw.json`.

6. **Start the agent**
   ```bash
   ./scripts/compose-up.sh sample-agent -d
   ```

7. **Verify**
   ```bash
   ./scripts/test-gateway-http.sh sample-agent
   ```
   You should see JSON from the gateway. Send a message via HTTP or Telegram if configured.

8. **Create another agent (optional)**
   ```bash
   ./scripts/create-agent.sh mybot
   cp agents/mybot/.env.example agents/mybot/.env
   # edit .env and config, then:
   ./scripts/compose-up.sh mybot -d
   ```
   For a **minimal agent** (lighter: one model, no PiGlow/IR/RFID/camera/productwatcher, etc.):
   ```bash
   ./scripts/create-agent.sh mybot --minimal
   ```

## Security — no secrets in git

- **Never** commit `.env` files or API keys. See [SECURITY.md](SECURITY.md).
- Use placeholders in docs and examples (`@your_bot`, `+1XXXXXXXXXX`, `admin@example.com`).
- Before opening a PR, run `./scripts/doctor.sh` and, if you have Docker, `./scripts/smoke-test.sh` to avoid obvious breakage.

## Creating a Pi-style agent

To run an agent on a Raspberry Pi with PiGlow, PiFace, IR, RFID, or camera, create an agent from the template and set `EXEC_HOST=gateway` and `HARDWARE_PROFILE=pi` in `agent.conf`. Full steps: [docs/RECREATING-PIBOT.md](docs/RECREATING-PIBOT.md) and [docs/RASPBERRY-PI-RUNBOOK.md](docs/RASPBERRY-PI-RUNBOOK.md).

## Scripts at a glance

| Script | Purpose |
|--------|---------|
| `create-agent.sh <name> [--minimal]` | Scaffold a new agent (use `--minimal` for a lighter agent) |
| `forge-agent.sh` | Interactive agent creation with model profiles |
| `compose-up.sh <name> [-d]` | Sync config and start the agent (use `-d` for detached) |
| `test-gateway-http.sh <name>` | Hit the gateway HTTP endpoint (expect JSON) |
| `list-agents.sh` | List all agents (excluding template) |
| `backup-agent.sh <name> [--output-dir <dir>]` | Create timestamped backup of config-runtime + logs (no .env); see [docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) |
| `rollout-image.sh` | Rebuild image and roll out to all agents; see [docs/UPGRADING.md](docs/UPGRADING.md) |
| `doctor.sh` | Preflight check (Docker, jq, template, .env) |
| `smoke-test.sh` | Create temp agent, start, test, teardown (optional CI) |

## Pull requests

- Keep changes focused; link to issues if applicable.
- Do not commit secrets or PII; the repo is scanned for common patterns.
- If you touch shell scripts, running `shellcheck` is appreciated (optional CI may add it).
