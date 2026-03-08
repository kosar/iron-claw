# IronClaw

Run one or many hardened [OpenClaw](https://openclaw.ai) agent gateways in Docker.
Each agent has its own container, config, workspace, skills, channels, and secrets.
The repo gives you one shared image plus scripts for setup, deploy, logs, and maintenance.

## Start here

If you are new, use this order:

1. Follow [Quick start](#quick-start).
2. Read [CONTRIBUTING.md](CONTRIBUTING.md) for setup and safety defaults.
3. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for runtime design.
4. Use [docs/TOOLS-AND-SKILLS.md](docs/TOOLS-AND-SKILLS.md) and [docs/MODEL-CHOICE.md](docs/MODEL-CHOICE.md) when you are choosing capabilities and models.

| **Running on a Raspberry Pi?** |
|--------------------------------|
| If you're running this on a Raspberry Pi, here's a [single command](#raspberry-pi-one-command-setup) to get it all set up on a fresh install. Once you're SSH'd into the Pi, that's all you need. |

## Prerequisites

- **Docker** and **Docker Compose**
- **[jq](https://jqlang.github.io/jq/)**: `apt install jq` (Debian/Ubuntu), `brew install jq` (macOS)

## Quick start

```bash
# 1. Clone and enter the repo
git clone <your-repo-url> ironclaw && cd ironclaw

# 2. Build the image
docker build -t ironclaw:2.0 .

# 3. Configure the sample agent
cp agents/template/.env.example agents/sample-agent/.env
```

Edit `agents/sample-agent/.env` and set at least:

- **OPENCLAW_GATEWAY_TOKEN**: for example `openssl rand -hex 24`
- **OPENCLAW_OWNER_DISPLAY_SECRET**: any secret value (required by OpenClaw)
- **OPENAI_API_KEY**: your OpenAI API key (or use Ollama-only in config)

```bash
# 4. Start the sample agent
./scripts/compose-up.sh sample-agent -d

# 5. Verify (expect JSON from the gateway)
./scripts/test-gateway-http.sh sample-agent
```

You should see a JSON response. Next: create your own agent with `./scripts/create-agent.sh mybot`, or add Telegram/WhatsApp in `config/openclaw.json` and `.env`. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full setup checklist.

## What IronClaw adds

- **Containerization**: one compose project per agent, each with its own port, volumes, and resource limits.
- **Security**: read-only filesystem (only mounted volumes writable), capabilities dropped, non-root (UID 1000), no-new-privileges.
- **Config discipline**: edit `config/` and `workspace/` on the host. The container mounts a **runtime** copy, and each start resyncs from source so a bad run cannot corrupt canonical config.
- **Operational scripts**: log analysis, cost tracking, failure detection, and gateway health checks. All take the agent name as the first argument.
- **Optional learning loop**: post-run feedback (reliability, efficiency) can be logged and optionally emailed to the owner. This is internal only and never shown to end users.
- **Factory model**: create new agents with `./scripts/create-agent.sh <name>` from one template, then customize as needed.

OpenClaw is installed at **image build** time via the official installer. Upgrading the gateway means rebuilding the image and redeploying (see [docs/UPGRADING.md](docs/UPGRADING.md)).

**A note on terminology.** We use OpenClaw’s terms here. An **agent** is one deployed instance: its config, personality (e.g. SOUL.md, AGENTS.md), and the channels and models you give it. **Tools** are the built-in capabilities OpenClaw provides (exec, read, write, web_fetch, browser, memory_search, and so on). **Skills** are custom capabilities you add under `workspace/skills/`: each has a SKILL.md (instructions for the model) and scripts the agent runs via the exec tool. So an agent uses tools and skills to do work; IronClaw is the layer that runs and hardens many such agents.

## Raspberry Pi: one-command setup

On **Raspberry Pi OS 64-bit** (Pi 4 or 5), you can set up IronClaw from a fresh install with a single command. The script updates the system, installs Docker and jq, clones this repo, builds the image, configures the sample-agent, starts the gateway, and enables start-on-boot. It explains each step as it runs.

You can [review the script in this repo](scripts/setup-raspberry-pi.sh) before running it.

```bash
curl -sSL https://raw.githubusercontent.com/kosar/iron-claw/main/scripts/setup-raspberry-pi.sh | bash
```

Options: `bash -s -- --yes` (non-interactive), `--help`, `--dry-run`. See the script header for details. After it finishes, set real secrets in `~/ironclaw/agents/sample-agent/.env`, then log out and back in (so the `docker` group applies) and optionally reboot to verify start-on-boot. **Before enabling Telegram** (or any channel), set `channels.telegram.allowFrom` to your numeric user ID(s) in `agents/sample-agent/config/openclaw.json` — the setup uses a placeholder so the gateway starts; keep `dmPolicy`/`groupPolicy` as `allowlist` so only approved contacts can message. See [SECURITY.md](SECURITY.md) and OpenClaw docs on DM policies.

## Project layout

```
ironclaw/
  Dockerfile                 # Shared image (ironclaw:2.0)
  scripts/
    lib.sh                   # Agent resolution (paths, agent.conf)
    docker-compose.yml.tmpl   # Per-agent compose (envsubst)
    compose-up.sh <agent>    # Sync config, then docker compose up
    create-agent.sh <name>   # New agent from template
    list-agents.sh
    test-gateway-http.sh
    watch-logs.sh, check-logs.sh, check-failures.sh, usage-summary.sh
    backup-agent.sh, rollout-image.sh, discover-ollama.sh
    heal-sessions.sh, prune-sessions.sh
  agents/
    template/                # Skeleton for new agents
    sample-agent/            # Runnable example
```

Each agent has: `agent.conf` (name, port, resources), `.env` (secrets, gitignored), `config/`, `workspace/`, and at runtime `config-runtime/`, `logs/`, and a generated `docker-compose.yml` (all gitignored).

## Commands

| Action | Command |
|--------|--------|
| Start agent | `./scripts/compose-up.sh sample-agent -d` |
| Full runtime reset | `./scripts/compose-up.sh sample-agent --fresh -d` |
| Stop | `docker compose -p sample-agent down` |
| New agent | `./scripts/create-agent.sh mybot` (or `--minimal` for lighter) |
| List agents | `./scripts/list-agents.sh` |
| Test gateway | `./scripts/test-gateway-http.sh sample-agent` |
| Live logs | `./scripts/watch-logs.sh sample-agent` |
| Recent logs | `./scripts/check-logs.sh sample-agent 50` |
| Failures | `./scripts/check-failures.sh sample-agent` |
| Token costs | `./scripts/usage-summary.sh sample-agent` |
| Backup | `./scripts/backup-agent.sh sample-agent` |

## Config workflow

1. Edit only under `agents/{name}/config/` and `agents/{name}/workspace/`.
2. Run `./scripts/compose-up.sh {name} -d` to sync and restart.
3. Secrets live in `agents/{name}/.env`; add new keys there and restart.

The container never writes to `config/`; it uses `config-runtime/`, which is refreshed from `config/` on each compose-up (sessions and memory are preserved).

## Channels

| Channel | Inbound | Pairing |
|---------|---------|--------|
| **Telegram** | Bot receives DMs/groups | Allowlist by numeric user ID in `allowFrom` |
| **WhatsApp** | API webhook | Allowlist by E.164 phone in `allowFrom` |
| **Email** | Outbound only | Gmail SMTP in `.env`; agent sends to addresses in USER.md or user request |

Enable each in `config/openclaw.json` under `channels`; put tokens in `.env`; restart after changes. We do not recommend iMessage for new setups (requires Mac + BlueBubbles and specific Apple ID setup).

## Models

Typical setup: a primary cloud model (e.g. OpenAI, Moonshot), an optional heartbeat model, and a fallback (e.g. Ollama on the host or LAN). Ollama base URL can be `http://host.docker.internal:11434` or a LAN IP. For Pi-style agents, `compose-up.sh` can run LAN discovery and set `OLLAMA_HOST` automatically when `HARDWARE_PROFILE=pi` is set in `agent.conf`. See [docs/MODEL-CHOICE.md](docs/MODEL-CHOICE.md).

## Tools and skills

Built-in tools include `exec`, `read`, `write`, `edit`, `web_fetch`, `browser`, `memory_search`, `sessions_list`, `cron`, `image`, and `message`.
Custom skills live under `workspace/skills/{name}/` (`SKILL.md` + scripts).
The template and sample-agent include four optional built-ins from the reference codebase: **shopify-nexus**, **fashion-radar**, **style-profile**, and **llm-manager**. They are disabled by default and can be enabled in `config/openclaw.json` under `skills.entries`.
For setup and behavior details, use [docs/TOOLS-AND-SKILLS.md](docs/TOOLS-AND-SKILLS.md).

## Raspberry Pi and exec

On hosts where the agent container has **no Docker inside** (e.g. Raspberry Pi), set `EXEC_HOST=gateway` in `agent.conf` so the exec tool runs in the same container as the gateway instead of trying to start a sandbox container. For PiGlow, PiFace, IR, RFID, camera, see [docs/RECREATING-PIBOT.md](docs/RECREATING-PIBOT.md) and [docs/RASPBERRY-PI-RUNBOOK.md](docs/RASPBERRY-PI-RUNBOOK.md).

## Learning feedback (optional)

On detached start, `learning-log-bridge.sh` runs unless `IRONCLAW_DISABLE_LEARNING_BRIDGE=1`. It scores each completed run and writes to `agents/{name}/logs/learning/`. Set `LEARNING_FEEDBACK_EMAIL` and `LEARNING_FEEDBACK_EMAIL_MODE` (immediate | digest | off) in `.env` to receive feedback by email.

## Known issues

- **Permission denied**: containers run as UID 1000. Ensure config-runtime, workspace, and logs are writable. On Pi with sudo, compose-up chowns config-runtime when `HARDWARE_PROFILE=pi`.
- **Ollama unreachable**: ensure Ollama listens on the expected interface (for example `0.0.0.0` for host.docker.internal).
- **Gateway won’t start with bind: lan**: set explicit `"controlUi": { "allowedOrigins": ["http://localhost:PORT", "http://127.0.0.1:PORT"] }` in the gateway section of `openclaw.json` (see [docs/RASPBERRY-PI-RUNBOOK.md](docs/RASPBERRY-PI-RUNBOOK.md)). Do **not** use `dangerouslyAllowHostHeaderOriginFallback`; explicit origins are sufficient and secure. Bind must stay `"lan"` for Docker port mapping to work.
- **Port conflict**: each agent needs a unique port. `create-agent.sh` assigns the next free one.

## Advanced: autonomous behavior and optional features

Out of the box, IronClaw does **not** enable the optional OpenClaw features that add heavy autonomous or multi-step behavior. The agent runs in a request-response style: it handles one conversation turn at a time. The only background behavior we configure is a lightweight **heartbeat** (e.g. every 2h) for memory maintenance. We do **not** enable **Lobster** (OpenClaw’s workflow engine for multi-step tool pipelines and approval-gated subprocesses), and we do **not** configure **nodes** or **canvas** (paired devices and display UI). So you don’t get workflow subprocesses, orchestrated pipelines, or device pairing by default; that keeps the system predictable and avoids surprising side effects when you first run an agent. If you need Lobster, richer subagent orchestration, or nodes/canvas, you can add them yourself in `config/openclaw.json` (e.g. `tools.alsoAllow`, subagent settings) and in OpenClaw’s docs; we leave that to you once your requirements call for it.

## Frequently Asked Questions

### What is OpenClaw?

OpenClaw is the runtime that keeps your agent alive and working.
You reach the agent through channels like Telegram, WhatsApp, iMessage (for example via BlueBubbles), webhooks, or other messaging surfaces.
OpenClaw receives those messages, calls models, runs tools and skills, and can also run scheduled/background work.
IronClaw is the deployment layer that runs one or many OpenClaw agents in isolated containers.

### Is this just ChatGPT?

No. ChatGPT is a chat product.
Here you build and run your own agent with your own model choices, personality, skills, channels, and deployment target.
Chat is one interface. The same agent can also run on schedules, react to webhooks, and use tools and memory without you in the loop.

### How do models fit in?

You talk to the agent through channels, and the agent calls LLM APIs under the hood.
You can use OpenAI models by adding an API key and selecting a per-agent model profile (for example GPT-4o or GPT-5-mini).
You can also run with local models by pointing the agent to Ollama or another local server.

### Why this repo exists

The goal is to run multiple OpenClaw agents in isolation without rebuilding security and ops from scratch each time.
IronClaw wraps the official gateway in one image, one compose stack per agent, and scripts that keep host config as source of truth and sync into runtime copies.
No Docker-in-Docker, and no writing back to canonical config.
This setup is used on Mac and Raspberry Pi with the same repo layout and process.

### How this can grow

You can start with a basic bot and then add memory-heavy skills, channel integrations, and more automation over time.
Optional skills like product discovery, style profiles, model switching, and reporting are ready to enable in config.
If you need heavier orchestration later, you can add Lobster workflows and related OpenClaw features without changing the core IronClaw deployment model.

## Docs

| Doc | Purpose |
|-----|---------|
| [CONTRIBUTING.md](CONTRIBUTING.md) | Setup checklist, security, PRs |
| [SECURITY.md](SECURITY.md) | Secrets, allowlists |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Config/exec/sandbox design |
| [docs/UPGRADING.md](docs/UPGRADING.md) | Rebuild image and roll out |
| [docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) | Backup and restore agent state |
| [docs/RECREATING-PIBOT.md](docs/RECREATING-PIBOT.md) | Pi-style agent with hardware |
| [docs/TOOLS-AND-SKILLS.md](docs/TOOLS-AND-SKILLS.md) | Tools and custom skills |
| [docs/MODEL-CHOICE.md](docs/MODEL-CHOICE.md) | Model selection (Ollama, tool support) |
| [IronClaw-TheoryOfOperation.md](IronClaw-TheoryOfOperation.md) | Deep technical reference |
