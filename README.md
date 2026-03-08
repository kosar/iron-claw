# IronClaw

A factory for running hardened [OpenClaw](https://openclaw.ai) agent gateways in Docker. Each agent gets its own container, config, personality, skills, and channels while sharing one locked-down image and a single operational toolchain.

**What is OpenClaw?** In the simplest terms: it’s the runtime that keeps your AI agent alive and working. You reach the agent through **channels**—connectors to the places people already chat: Telegram, WhatsApp, iMessage (e.g. via BlueBubbles), webhooks, or other messaging surfaces. That’s the important bit: one agent framework, one personality and set of skills, but users (or you) talk to it from the apps they already use. No custom UI to build, no “go log into our dashboard”—the agent is just there, in the thread. OpenClaw receives messages from those channels, calls the model and runs tools or skills, and can do scheduled or background work—like a **daemon** that’s always on, or a **cron** that can run both on a schedule and in response to events. You give it config, a workspace, and optional skills; it handles the rest. IronClaw is the layer that runs one or many of these “agent processes” in isolated containers, the same way an OS runs many daemons or cron jobs.

You can use IronClaw to build agents that grow with you: they keep their history and lessons learned (memory, logs, skill knowledge files), so over time they become more autonomous, more capable, and more tailored to your use case—without a big upfront design. Start from a solid base: OpenClaw’s built-in tools and a small set of optional skills (product discovery, style profiles, model switching, daily reports) that are ready to enable in config. Add your own skills under `workspace/skills/` when you need them, and as the agent runs it can extend itself with new skills and refinements. When you need to go further, the same stack can scale: you can enable **Lobster** (OpenClaw’s workflow engine), add subprocesses and self-driven workflows, and layer on more orchestration so one agent can run multi-step pipelines and approval-gated work without changing the box it runs in. The result is a clear path from “one bot that answers questions” to a personalized assistant that remembers context, uses the right skill for each task, and can adopt new capabilities—or whole workflows—as your needs grow.

**What we're doing.** We wanted to run multiple OpenClaw agents in isolation without hand-rolling config or security each time. So we wrapped the official gateway in a single image, one compose stack per agent, and scripts that keep host config as source of truth and sync into a runtime copy the container actually sees. No Docker inside the container, no writing back to your config. Once an agent is up, we don't get in the way: personalization and configuration happen as usual with OpenClaw (same config files, workspace, skills, channels). This is just the box it runs in. We dogfooded this on a Mac (several agents, cloud + local models) and on a Raspberry Pi (one agent, hardware like PiGlow and IR). Same repo, same design: you get a known-good setup whether you're on a laptop or a Pi, and the docs reflect what we actually run.

## Prerequisites

- **Docker** and **Docker Compose**
- **[jq](https://jqlang.github.io/jq/)** — e.g. `apt install jq` (Debian/Ubuntu), `brew install jq` (macOS)

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

- **OPENCLAW_GATEWAY_TOKEN** — e.g. `openssl rand -hex 24`
- **OPENCLAW_OWNER_DISPLAY_SECRET** — any secret value (required by OpenClaw)
- **OPENAI_API_KEY** — your OpenAI API key (or use Ollama-only in config)

```bash
# 4. Start the sample agent
./scripts/compose-up.sh sample-agent -d

# 5. Verify (expect JSON from the gateway)
./scripts/test-gateway-http.sh sample-agent
```

You should see a JSON response. Next: create your own agent with `./scripts/create-agent.sh mybot`, or add Telegram/WhatsApp in `config/openclaw.json` and `.env`. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full setup checklist.

## What IronClaw adds

- **Containerization** — One compose project per agent; each gets its own port, volumes, and resource limits.
- **Security** — Read-only filesystem (only mounted volumes writable), capabilities dropped, non-root (UID 1000), no-new-privileges.
- **Config discipline** — You edit `config/` and `workspace/` on the host. The container mounts a **runtime** copy; the next start resyncs from your source, so a bad run cannot corrupt the canonical config.
- **Operational scripts** — Log analysis, cost tracking, failure detection, gateway health checks. All take the agent name as the first argument.
- **Optional learning loop** — Post-run feedback (reliability, efficiency) can be logged and optionally emailed to the owner; internal only, never shown to end users.
- **Factory model** — New agents are created with `./scripts/create-agent.sh <name>` from a single template; customization is additive.

OpenClaw is installed at **image build** time via the official installer. Upgrading the gateway means rebuilding the image and redeploying (see [docs/UPGRADING.md](docs/UPGRADING.md)).

**A note on terminology.** We use OpenClaw’s terms here. An **agent** is one deployed instance: its config, personality (e.g. SOUL.md, AGENTS.md), and the channels and models you give it. **Tools** are the built-in capabilities OpenClaw provides (exec, read, write, web_fetch, browser, memory_search, and so on). **Skills** are custom capabilities you add under `workspace/skills/`: each has a SKILL.md (instructions for the model) and scripts the agent runs via the exec tool. So an agent uses tools and skills to do work; IronClaw is the layer that runs and hardens many such agents.

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

Built-in tools: `exec`, `read`, `write`, `edit`, `web_fetch`, `browser`, `memory_search`, `sessions_list`, `cron`, `image`, `message`. Custom skills live under `workspace/skills/{name}/` (SKILL.md + scripts). The template and sample-agent include optional IronClaw built-ins ported from the reference codebase: **shopify-nexus** (Shopify MCP product/policy search, optional Chatsi Genius), **fashion-radar** (trend intelligence), **style-profile** (per-customer style memory), and **llm-manager** (runtime model tier switching). All four are disabled by default; enable in `config/openclaw.json` under `skills.entries`. See [docs/TOOLS-AND-SKILLS.md](docs/TOOLS-AND-SKILLS.md).

## Raspberry Pi and exec

On hosts where the agent container has **no Docker inside** (e.g. Raspberry Pi), set `EXEC_HOST=gateway` in `agent.conf` so the exec tool runs in the same container as the gateway instead of trying to start a sandbox container. For PiGlow, PiFace, IR, RFID, camera, see [docs/RECREATING-PIBOT.md](docs/RECREATING-PIBOT.md) and [docs/RASPBERRY-PI-RUNBOOK.md](docs/RASPBERRY-PI-RUNBOOK.md).

## Learning feedback (optional)

On detached start, `learning-log-bridge.sh` runs unless `IRONCLAW_DISABLE_LEARNING_BRIDGE=1`. It scores each completed run and writes to `agents/{name}/logs/learning/`. Set `LEARNING_FEEDBACK_EMAIL` and `LEARNING_FEEDBACK_EMAIL_MODE` (immediate | digest | off) in `.env` to receive feedback by email.

## Known issues

- **Permission denied** — Containers run as UID 1000; ensure config-runtime, workspace, and logs are writable. On Pi with sudo, compose-up chowns config-runtime when `HARDWARE_PROFILE=pi`.
- **Ollama unreachable** — Ensure Ollama listens on the expected interface (e.g. `0.0.0.0` for host.docker.internal).
- **Gateway won’t start with bind: lan** — Add `"controlUi": { "dangerouslyAllowHostHeaderOriginFallback": true }` in the gateway section of `openclaw.json` (see [docs/RASPBERRY-PI-RUNBOOK.md](docs/RASPBERRY-PI-RUNBOOK.md)).
- **Port conflict** — Each agent needs a unique port; `create-agent.sh` assigns the next free one.

## Advanced: autonomous behavior and optional features

Out of the box, IronClaw does **not** enable the optional OpenClaw features that add heavy autonomous or multi-step behavior. The agent runs in a request-response style: it handles one conversation turn at a time. The only background behavior we configure is a lightweight **heartbeat** (e.g. every 2h) for memory maintenance. We do **not** enable **Lobster** (OpenClaw’s workflow engine for multi-step tool pipelines and approval-gated subprocesses), and we do **not** configure **nodes** or **canvas** (paired devices and display UI). So you don’t get workflow subprocesses, orchestrated pipelines, or device pairing by default; that keeps the system predictable and avoids surprising side effects when you first run an agent. If you need Lobster, richer subagent orchestration, or nodes/canvas, you can add them yourself in `config/openclaw.json` (e.g. `tools.alsoAllow`, subagent settings) and in OpenClaw’s docs; we leave that to you once your requirements call for it.

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
