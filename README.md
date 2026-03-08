# IronClaw Core: Hardened Multi-Agent Factory on OpenClaw

IronClaw Core is a factory for deploying hardened OpenClaw agent instances in Docker. Each agent is a full OpenClaw gateway with its own personality, skills, channels, secrets, and resource limits, sharing one locked-down image and a single operational toolchain.

---

## Getting Started

**Prerequisites:** Docker, Docker Compose, and [jq](https://jqlang.github.io/jq/) (e.g. `brew install jq` on macOS, `apt install jq` on Debian/Ubuntu).

```bash
# 1. Clone and enter the repo
git clone https://github.com/kosar/iron-claw.git ironclaw && cd ironclaw

# 2. Build the image (tag must match what compose expects)
docker build -t ironclaw:2.0 .

# 3. Configure the sample agent (create .env from template)
cp agents/template/.env.example agents/sample-agent/.env
```

Edit `agents/sample-agent/.env` and set at least:

- **OPENCLAW_GATEWAY_TOKEN**: e.g. `openssl rand -hex 24`
- **OPENCLAW_OWNER_DISPLAY_SECRET**: any secret value (required by OpenClaw)
- **OPENAI_API_KEY**: your OpenAI API key (or use Ollama-only in config)

```bash
# 4. Start the sample agent
./scripts/compose-up.sh sample-agent -d

# 5. Verify (expect JSON from the gateway)
./scripts/test-gateway-http.sh sample-agent
```

You should see a JSON response (e.g. `"content":"sample-agent is working."`). Next: create your own agent with `./scripts/create-agent.sh mybot`, or add Telegram/WhatsApp in `config/openclaw.json` and `.env`. See [Quick Start](#quick-start) and [CONTRIBUTING.md](CONTRIBUTING.md) for more.

---

## What IronClaw Adds on Top of OpenClaw

**OpenClaw** is the runtime: LLM routing, tool execution, channel adapters (Telegram, WhatsApp, BlueBubbles, HTTP), heartbeat, cron, browser, memory, skills. IronClaw does not replace it; it wraps it.

**IronClaw** adds what OpenClaw leaves to the operator:

- **Containerization and isolation**: One compose project per agent; each gets its own network namespace, port, and volumes.
- **Security hardening**: Read-only filesystem (only mounted volumes are writable), all capabilities dropped, `no-new-privileges`, non-root (UID 1000). The gateway binds inside the container; host-side port mapping restricts who can reach it (e.g. `127.0.0.1:18789` only).
- **Config discipline**: The host holds the source config in `config/`; the container never writes there. `compose-up.sh` syncs `config/` into `config-runtime/` and the container mounts only `config-runtime/`. So a bad run cannot corrupt the canonical config; the next start resyncs from a clean copy. (See [Separation, Boundaries, and Execution](#separation-boundaries-and-execution-the-ironclaw-model) for the full picture of how config, runtime, exec, and workspace fit together.)
- **Operational scripts**: Log analysis, cost tracking, session pruning, failure detection, session healing (e.g. stripping reasoning items that break replay), gateway health checks. All take the agent name as the first argument and use `lib.sh` for paths and `agent.conf` values.
- **Built-in post-run learning loop**: Every completed run (`embedded run done`) can be scored for reliability/efficiency/hygiene, logged to owner-only feedback files, and optionally sent to the owner/configurator by email. This is internal-only and never shown to end users.
- **Factory model**: A single template under `agents/template/`; new agents are created with `create-agent.sh`, which copies the template, assigns a port, and writes `agent.conf`. Every agent starts from full OpenClaw defaults; customization is additive (personality, skills, channels, limits).

OpenClaw is not updated from inside the container. The image is built from the official installer (`openclaw.ai/install.sh`) at **build** time; the filesystem is read-only and there is no in-container upgrade path. Upgrading the gateway means rebuilding the image and redeploying. In practice we track upstream, watch for divergences, and adopt new versions deliberately rather than automatically.

---

## From OpenClaw to a Running Agent

Rough pipeline:

1. **Upstream**: An official OpenClaw release (install script, npm package, behavior).
2. **Image**: Dockerfile installs Node, system deps (Chromium, ffmpeg, ripgrep, python3), renames the node user to `ai_sandbox`, runs the install script as that user, and sets `CMD ["openclaw", "gateway"]`. You build with `docker build -t ironclaw:2.0 .` (or the tag your compose template expects). Same Dockerfile on Mac and Pi; build on the machine (or arch) you will run on.
3. **Agent scaffold**: `./scripts/create-agent.sh <name> [admin-email]` creates `agents/<name>/` from the template, assigns the next free port, and creates `agent.conf` and `.env` from examples. You then fill in secrets and optionally tune `agent.conf` (RAM, CPUs, SHM).
4. **Config and safety**: Edit only `config/` and `workspace/` on the host. Before every start, `compose-up.sh` syncs config, injects port and (for agents with HARDWARE_PROFILE=pi) LAN-discovered Ollama host, runs session pruning and session healing (so broken reasoning state does not cause 400s on replay), and generates `docker-compose.yml` from the template via `envsubst`. So the container always starts from a prepared, consistent state.
5. **Start**: `./scripts/compose-up.sh <name> -d` runs the sync steps above and then `docker compose -p <name> up -d`. The agent’s “powers” (tools, skills, channels) are whatever you enabled in config and workspace; onboarding is methodical (e.g. TODO.md in workspace, heartbeat-driven setup) rather than all-at-once.

So: **raw OpenClaw → IronClaw image and scripts → hardened, controlled container → agent brought up gradually with clear config and limits.**

---

## Model and “Local” Strategy

The original design leaned heavily on “run locally” (e.g. Ollama on the host). That has shifted. Today the stack is:

- **Multiple online providers**: OpenAI, Moonshot (Kimi), and others are configured per agent. Primary and fallback models are chosen per use case (e.g. heartbeat vs. chat).
- **Heavy work**: The most capable or expensive work often runs on paid APIs; what can be done quickly and well locally is still offloaded when it makes sense.
- **“Local” now means LAN**: The host that runs the container is on a local area network. We do **not** assume Ollama is on the same machine. We assume there may be Ollama servers elsewhere on the LAN (ports open, IPs reachable). The host runs a **LAN scan** (e.g. `scripts/discover-ollama.sh`) to find those hosts and optionally pass one in as `OLLAMA_HOST` for the container. Inside the container, `SCAN_SUBNET` is set from the host’s subnet so skills (e.g. image-gen) can also discover Ollama on the LAN and use those models without API keys. So “local” is “on the same network,” not “on the same box,” and we still get frugality where it matters (models on the LAN are used when available) without making that the center of the design.

Example: for agents with **HARDWARE_PROFILE=pi** (e.g. on a Raspberry Pi), `compose-up.sh` runs `discover-ollama.sh` before starting; if an Ollama host is found on the LAN (other than localhost / host.docker.internal), it is set as `OLLAMA_HOST` so the container can use it. On a Mac, `host.docker.internal` is typically used so the container talks to Ollama on the host. In both cases the container receives `SCAN_SUBNET` so any in-container logic that scans for Ollama (e.g. in skills) sees the same network.

---

## Architecture: Concentric Layers

```
┌─────────────────────────────────────────────────────┐
│                    Your Agents                       │
│   sample-agent  ·  mybot  ·  ...                     │
│   Personality, skills, channels, memory              │
├─────────────────────────────────────────────────────┤
│                  IronClaw Core                       │
│   Factory, hardening, compose, scripts,              │
│   config sync, session heal/prune, LAN discovery     │
├─────────────────────────────────────────────────────┤
│                    OpenClaw                          │
│   Gateway, LLM routing, tools, channels, skills     │
└─────────────────────────────────────────────────────┘
```

Agents are the outermost layer: identity (SOUL.md, IDENTITY.md), behavior (AGENTS.md), skills, and channels. The template ships full OpenClaw defaults; agents only add what differentiates them.

---

## Separation, Boundaries, and Execution: The IronClaw Model

This section explains how IronClaw achieves the separation we care about: **immutable config**, **one clear security boundary**, and **predictable execution** so agents and skills work reliably instead of failing in subtle, host-vs-container ways. This is the core of the value proposition.

### What we’re separating

1. **Source of truth vs. runtime state**: The host holds the canonical config and workspace; the container never writes to them. Runtime state (sessions, memory, container-written files) lives in `config-runtime/`, which is repopulated from `config/` on every start (with exclusions so we don’t lose sessions). So a bad run or a bug cannot corrupt “what you intended”; the next `compose-up` resyncs from a clean copy.
2. **Who can do what**: The container is the single security boundary. It’s locked down (read-only filesystem except mounts, no capabilities, non-root, resource limits). Everything the agent does (tools, exec, skills) happens inside that boundary. We do **not** give the container Docker or the host’s Docker socket; we don’t run “Docker inside the container” for extra isolation. The container *is* the isolation.
3. **Where exec runs**: OpenClaw’s **exec** tool can run commands in different places: **gateway** (same process as the gateway), **node** (a separate node host), or **sandbox**. In OpenClaw’s design, **sandbox** means “run the command in a separate Docker container” for isolation. That requires the `docker` binary and a Docker daemon. Our agent containers don’t have Docker inside them: they *are* the container. So if we set `host=sandbox`, OpenClaw tries to spawn another container and fails (`spawn docker ENOENT`). The fix is to run exec in the **gateway** context: the command runs in the same container as the gateway. We still get one clear boundary (the container); we just don’t add a second layer of containers inside it.

### Why gateway exec (not sandbox) for agents in Docker

- **Sandbox** in OpenClaw = “run in a separate Docker container.” So sandbox requires Docker to be available where the gateway runs. Inside our hardened container there is no Docker, so sandbox is unavailable.
- **Gateway** = “run in the gateway’s environment.” When the gateway runs inside our container, that environment *is* the container. So exec runs there: same filesystem, same network, same env. No extra privilege, no Docker-in-Docker, no socket mount.
- We **could** install Docker in the container or mount the host’s Docker socket so OpenClaw could spawn sandbox containers. That would mean the container (or the gateway) can create containers on the host, which is a much larger trust and operational burden. For our use case (controlled skills, allowlisted exec, single-tenant agents) the container is already the right boundary. Gateway exec is the right choice.

**Per-agent behavior:** For any agent that runs where **Docker is not available inside the container** (e.g. Raspberry Pi, or when you do not want OpenClaw to spawn sandbox containers), set `EXEC_HOST=gateway` in that agent’s `agent.conf`. Then `compose-up.sh` injects `agents.defaults.sandbox.mode: "off"` and `tools.exec.host: "gateway"` so exec runs in the same container as the gateway. For other agents (e.g. on a Mac where sandbox might be used later), the script injects `host: "sandbox"`. The source of truth is `agent.conf`; the container never “remembers” the wrong value across restarts.

**Why this matters for limited-hardware or “no Docker-in-container” agents:** On a Raspberry Pi (or any host where the agent container has no Docker inside it), the agent often needs to reach **services on the host** (e.g. PiGlow, PiFace, IR blaster, camera, log bridge) via HTTP (`host.docker.internal`) or device passthrough. Exec must run **in the gateway** so those scripts and tools actually run. If exec were set to sandbox, OpenClaw would try to run commands in a separate Docker container that we do not provide, and exec would be blocked. We encode the policy in the repo: such agents set `EXEC_HOST=gateway` in `agent.conf`. On every `compose-up`, the script injects the correct `tools.exec.host` and `agents.defaults.sandbox.mode`. Full Raspberry Pi setup (PiGlow, IR, RFID, camera, Telegram) is in [docs/RECREATING-PIBOT.md](docs/RECREATING-PIBOT.md) and [docs/RASPBERRY-PI-RUNBOOK.md](docs/RASPBERRY-PI-RUNBOOK.md).

### Workspace and file paths: one shared view

Tools like **write** and **exec** both run inside the same container, but they must agree on where files live. If the agent uses **write** to create a file in `/tmp` and then passes that path to **exec**, the exec might not see the same `/tmp` (e.g. if OpenClaw had used a sandbox with a different filesystem view). We avoid that class of bug with a single rule: **any file the agent creates and then passes to exec (or between execs) must live under the workspace**, i.e. under `/home/ai_sandbox/.openclaw/workspace/...`, which is the mounted host `workspace/` directory. Both the write tool and exec see the same mount, so the path is valid for both. Skills are written to assume workspace paths (e.g. body file for send-email, generated image path for image-gen). We document this as Rule 6b in agent guidelines so the model doesn’t use `/tmp` for cross-tool files.

### Credentials and exec: getting secrets where they’re needed

Secrets live in the agent’s `.env` on the host. The container gets them via Docker’s `env_file` and `environment`. When exec runs in **gateway** mode, it runs in the same process environment, so it normally inherits those variables. For robustness (e.g. if some code path doesn’t pass env through), we also support scripts that read credentials from a file. Example: the **send-email** skill. `compose-up.sh` copies `SMTP_FROM_EMAIL` and `GMAIL_APP_PASSWORD` from the agent’s `.env` into `workspace/skills/send-email/.env`. The send-email script tries env first, then that file. So the script works whether or not the exec environment inherited the Docker env. That file is gitignored and never committed.

### Self-healing so the setup stays correct

We don’t rely on the container or OpenClaw to “remember” the right exec host or sandbox mode. On **every** `compose-up`, we inject into config-runtime:

- The agent’s port (from `agent.conf`).
- For agents with **EXEC_HOST=gateway**: `sandbox.mode: "off"` and `tools.exec.host: "gateway"` (and `security: "full"`, `ask: "off"`).
- For **other agents**: `tools.exec.host: "sandbox"` (and the same security/ask settings).

So even if config-runtime were edited or OpenClaw wrote something back, the next compose-up restores the intended state. The host and the scripts own the policy; the container just runs it.

### How it all fits together

- **Host** holds `config/`, `workspace/`, and `.env`. You only edit there.
- **compose-up.sh** syncs config → config-runtime, injects port and exec/sandbox settings, writes any skill-specific credential files (e.g. send-email `.env`) into workspace, then starts the container with config-runtime and workspace mounted.
- **Container** sees only config-runtime and workspace (and logs). It runs the gateway and, for agents with EXEC_HOST=gateway, exec in the same process space (gateway). No Docker inside; the container is the boundary.
- **Agent** uses tools and skills; files that must be shared between write and exec live in workspace; credentials come from env or from workspace files written by compose-up. The result is a single, predictable configuration that stays correct across restarts and avoids the “works on the host but not in the agent” and “sandbox unavailable” failures we designed away.

---

## Project Layout

```
ironclaw/
  Dockerfile                    # Shared image (ironclaw:2.0)
  scripts/
    lib.sh                      # Agent resolution (source agent.conf, set AGENT_*)
    docker-compose.yml.tmpl     # Per-agent compose (envsubst)
    compose-up.sh <agent> [-d]  # Sync config, heal, generate compose, up
    create-agent.sh <name> [--minimal] [email]
    list-agents.sh
    compose-up-all.sh
    backup-agent.sh <name>      # Timestamped backup of config-runtime + logs (see docs/BACKUP-RESTORE.md)
    rollout-image.sh            # Rebuild image and compose-up all agents (see docs/UPGRADING.md)
    discover-ollama.sh          # LAN scan for Ollama (used by compose-up when HARDWARE_PROFILE=pi)
    heal-sessions.sh, prune-sessions.sh
    watch-logs.sh, check-logs.sh, check-failures.sh, analyze-logs.sh
    usage-summary.sh
    test-gateway-http.sh
  agents/
    template/                   # Full OpenClaw skeleton; new agents copy from here
    sample-agent/               # One runnable example (create more with create-agent.sh)
  docs/
    BACKUP-RESTORE.md           # Backup and restore agent state
    UPGRADING.md                # Upgrade image and roll out to all agents
```

Each agent directory has: `agent.conf`, `.env` (gitignored), `config/`, `workspace/`, and at runtime `config-runtime/` (gitignored), `logs/` (gitignored), and a generated `docker-compose.yml` (gitignored).

---

## Agent Anatomy

| Component | Purpose |
|-----------|---------|
| `agent.conf` | Name, port, container name, memory limit, CPUs, SHM size |
| `.env` | Secrets (gateway token, API keys, channel tokens) |
| `config/openclaw.json` | Gateway config: models, channels, tools, skills |
| `workspace/SOUL.md` | Personality and style |
| `workspace/AGENTS.md` | Behavioral rules, tool use, decision flows |
| `workspace/IDENTITY.md` | Name, creature type, deployment notes |
| `workspace/skills/` | Custom skills (SKILL.md + scripts) |
| `workspace/HARDWARE.md` | (Pi-style agents, optional) When present, disables PiGlow/PiFace execs on this instance; gitignored. See `HARDWARE.md.example`. |

Host `workspace/AGENTS.md` is prepended into `config-runtime/workspace/AGENTS.md` by `compose-up.sh` so agent guidelines stay under version control. Skills and scripts in `workspace/` are rsynced into `config-runtime/workspace/` so the container sees the latest versions without editing inside the container.

---

## Security Hardening (Same for Every Agent)

- **Read-only filesystem**: Writable only where volumes are mounted.
- **Capabilities**: All dropped (`cap_drop: [ALL]`).
- **Privilege escalation**: Disabled (`no-new-privileges: true`).
- **User**: `1000:1000` (ai_sandbox), not root.
- **Port**: Bound inside the container; host mapping (e.g. `127.0.0.1:${AGENT_PORT}:${AGENT_PORT}`) limits who can connect.
- **Init**: Tini reaps zombies (e.g. from Chromium).
- **Resources**: `mem_limit`, `cpus`, `shm_size` from `agent.conf`.

This follows standard containment practice: assume the payload might be coerced or misused, and limit blast radius with layers (filesystem, capabilities, user, network, resources).

---

## Agents: sample-agent and the template

The repo ships a **sample-agent** (one runnable example) and a **template** from which you create more agents with `./scripts/create-agent.sh <name>` (or `--minimal` for a lighter agent). The agent **name** (e.g. sample-agent, mybot) is the directory under `agents/`; the **instance** is that agent running in a container, wired to your Telegram bot, email, WhatsApp, or HTTP. Configure channels and allowlists in each agent's `config/openclaw.json` and `.env`.

### sample-agent

Default runnable example. Create more agents with `./scripts/create-agent.sh <name>`. For a **Raspberry Pi–style agent** (PiGlow, PiFace, IR, RFID, camera), set `EXEC_HOST=gateway` and `HARDWARE_PROFILE=pi` in `agent.conf` and follow [docs/RECREATING-PIBOT.md](docs/RECREATING-PIBOT.md) and [docs/RASPBERRY-PI-RUNBOOK.md](docs/RASPBERRY-PI-RUNBOOK.md). On headless or no-hardware hosts, create `agents/<name>/workspace/HARDWARE.md` from `HARDWARE.md.example` so the agent skips PiGlow/PiFace execs.

---

## Quick Start

```bash
# Start the sample agent (after copying .env.example to .env and setting secrets)
./scripts/compose-up.sh sample-agent -d

# Create a new agent (port auto-assigned); use --minimal for a lighter agent
./scripts/create-agent.sh mybot admin@example.com
# Edit agents/mybot/.env (OPENCLAW_GATEWAY_TOKEN, OPENAI_API_KEY, etc.)
# Edit agents/mybot/workspace/ (IDENTITY.md, SOUL.md, USER.md)
./scripts/compose-up.sh mybot -d
./scripts/test-gateway-http.sh mybot

# List agents and status
./scripts/list-agents.sh

# Backup agent state (config-runtime + logs); restore see docs/BACKUP-RESTORE.md
./scripts/backup-agent.sh sample-agent

# Full runtime reset (keeps config source, wipes config-runtime and repopulates)
./scripts/compose-up.sh sample-agent --fresh -d
```

---

## Config Workflow

1. Edit only under `agents/{name}/config/` and `agents/{name}/workspace/`.
2. Run `./scripts/compose-up.sh {name} -d` to sync and restart.
3. Secrets live in `agents/{name}/.env` and are referenced in config as `${VAR_NAME}`.
4. To add a new API key or channel token, add it to `.env` and restart.

The container never writes to `config/`; it only sees `config-runtime/`, which is refreshed from `config/` (with exclusions for sessions, memory, and other runtime state) on each compose-up.

---

## Channels: Telegram, WhatsApp, Email

The three channels that work best for users are **Telegram**, **WhatsApp**, and **email**. We do not recommend iMessage for now: it requires a Mac running BlueBubbles (Messages.app bridge, Private API, webhooks), a specific Apple ID and permissions setup, and we have not yet optimized or hardened that path. The following is a high-level view of how each of the three works and how pairing or allowlisting is done (no secrets, just mechanics).

### Telegram

**How it works:** OpenClaw runs a Telegram **bot**. You create the bot with Telegram’s BotFather and get a bot token. The gateway uses that token to poll (or receive webhooks) for new messages. When a user sends a message to the bot, OpenClaw gets the update, runs the agent, and sends the reply as the bot. All traffic is between the gateway and Telegram’s API; Telegram handles delivery to the user’s app.

**Pairing / allowlist:** Telegram identifies users by a **numeric user ID** (not username). By default we use an allowlist: only IDs in `allowFrom` in `config/openclaw.json` can talk to the bot. So “pairing” is: (1) the user messages the bot or uses a helper bot to learn their numeric ID, (2) you add that ID to `allowFrom`, (3) restart or resync so the config is loaded. No shared secret with the user; the gate is “only these IDs.” You can also use a pairing flow where new users get a one-time code and you approve them before adding to the allowlist; that’s a policy choice in config (`dmPolicy`, `groupPolicy`).

**Why it’s reliable:** Single well-documented API, webhooks or long polling, no extra host process. The container only needs outbound HTTPS to Telegram. Works the same on Mac, Pi, or any host.

### WhatsApp

**How it works:** OpenClaw’s WhatsApp channel talks to the WhatsApp Cloud API (or a compatible bridge). You obtain credentials and optionally a phone number from Meta’s developer flow. The gateway receives incoming messages via webhook and sends replies through the same API. Delivery and presence are handled by WhatsApp; the agent only sees the conversation as messages in and out.

**Pairing / allowlist:** WhatsApp identifies users by **E.164 phone number** (e.g. `+14255551234`). As with Telegram, we typically restrict who can talk to the agent via an allowlist: only numbers in `allowFrom` are accepted. So “pairing” is: (1) user has a phone number that will chat with the agent, (2) you add that number in E.164 form to `allowFrom` in the channel config, (3) reload config. There may also be a verification or opt-in step required by WhatsApp’s policies (e.g. user must send a keyword or first message before the business can reply). Check OpenClaw’s WhatsApp channel docs for the exact flow.

**Why it’s reliable:** Standard business API, webhook-based, no local app or bridge on your machine. Works from any host that can reach the internet and receive webhooks (gateway must be reachable for webhook URL).

### Email

**How it works:** In this setup, email is **outbound only**. The agent does not receive inbound mail as a real-time channel. Instead, the agent *sends* email when it needs to (reports, summaries, onboarding status, or “email this to me”) using a workspace script that talks to Gmail’s SMTP. You put the Gmail address and an app password in the agent’s `.env`; the script uses those to send. So “email as a channel” means: the user gets replies or digests by email when the agent chooses to send, or when the user asks “email me the answer.” Inbound conversation usually happens over Telegram or WhatsApp; email is the delivery mechanism for longer or asynchronous content.

**Pairing / allowlist:** There is no allowlist in config for email. The agent sends to addresses you give it in `workspace/USER.md` (e.g. owner email), or to addresses the user specifies in the conversation (“email this to me at x@y.com”). So “pairing” is: (1) set `SMTP_FROM_EMAIL` and `GMAIL_APP_PASSWORD` in `.env` so the agent can send, (2) document the owner or default recipient in USER.md or let the user say where to send. No per-address allowlist; the agent uses the tool only when the task implies sending (e.g. “email me the report”).

**Why it’s useful:** Works everywhere, no extra service. Good for summaries, logs, and “send this to my inbox” without opening another app. Combines well with Telegram or WhatsApp for the main conversation.

### Summary

| Channel   | Inbound              | Pairing / gate           | Notes                                      |
|----------|----------------------|--------------------------|--------------------------------------------|
| Telegram | Bot receives DMs/groups | Allowlist by numeric user ID | Token in `.env`; add IDs to `allowFrom`     |
| WhatsApp | API webhook          | Allowlist by E.164 phone  | Credentials in `.env`; add numbers to `allowFrom` |
| Email    | Outbound only        | None (agent sends to given addresses) | Gmail SMTP in `.env`; USER.md or user says where to send |

Enable each channel in `config/openclaw.json` under `channels` and the corresponding `plugins.entries`; put tokens and secrets in `.env`; restart after changes.

---

## Monitoring and Logs

Scripts take the agent name as the first argument:

| What | Command |
|------|---------|
| Live log monitor | `./scripts/watch-logs.sh sample-agent` |
| Recent lines | `./scripts/check-logs.sh sample-agent 50` |
| Stream | `./scripts/check-logs.sh sample-agent follow` |
| Failure analysis | `./scripts/check-failures.sh sample-agent` |
| Token/cost summary | `./scripts/usage-summary.sh sample-agent` |
| Internal learning bridge log | `tail -f agents/sample-agent/logs/learning-bridge.log` |
| Latest quality feedback snapshot | `cat agents/sample-agent/logs/learning/latest-feedback.txt` |
| Quality trend history stream | `tail -n 50 agents/sample-agent/logs/learning/quality-timeseries.jsonl` |
| All agents | `./scripts/list-agents.sh` |

Two log sources: Docker stdout (`docker logs -f {name}_secure`) for startup and channel auth; app log under `agents/{name}/logs/openclaw-YYYY-MM-DD.log` (JSON lines, run lifecycle, model, tools, costs).

### Built-in post-run learning feedback (owner-only)

On detached starts (`./scripts/compose-up.sh <agent> -d`), IronClaw auto-starts `scripts/learning-log-bridge.sh` for that agent (unless `IRONCLAW_DISABLE_LEARNING_BRIDGE=1`).

- Trigger: each `embedded run done` event (native completed run/lane unit)
- Evaluator: `scripts/learning-feedback.py`
  - deterministic subscores: reliability, efficiency, process hygiene
  - optional frugal LLM-as-judge calibration (`LEARNING_FEEDBACK_DISABLE_LLM_JUDGE=false`)
- Output (gitignored): `agents/{name}/logs/learning/feedback-YYYY-MM-DD.jsonl`, `quality-timeseries.jsonl`, and `latest-feedback.txt`
- Historical analytics:
  - short/long window quality deltas (up/down/flat)
  - feedback-uptake tracker (improved vs not_improved after coaching)
  - trend signals to detect quality changes in either direction
- Owner delivery:
  - `LEARNING_FEEDBACK_EMAIL_MODE=immediate` → email every run
  - `LEARNING_FEEDBACK_EMAIL_MODE=digest` → queue and send digest by run/time thresholds
  - `LEARNING_FEEDBACK_EMAIL_MODE=off` → logging only, no email
- Safety: feedback is strictly internal and never posted to user channels

Optional env switches in `agents/{name}/.env`:

```bash
LEARNING_FEEDBACK_EMAIL=owner@yourdomain.com
LEARNING_FEEDBACK_EMAIL_MODE=digest      # immediate | digest | off
LEARNING_FEEDBACK_DIGEST_MIN_RUNS=10
LEARNING_FEEDBACK_DIGEST_MINUTES=120
LEARNING_FEEDBACK_DISABLE_LLM_JUDGE=false
```

---

## Model Stack (Typical)

- **Primary**: e.g. `openai/gpt-5-mini` or `moonshot/kimi-k2.5` depending on agent; reasoning and context as needed.
- **Heartbeat**: Lighter model (e.g. `gpt-5-nano`) for periodic memory maintenance.
- **Fallback**: Often `ollama/qwen3:8b` or similar, with base URL pointing at `OLLAMA_HOST` (host or LAN-discovered). Failover on auth/rate-limit/timeout, not on connection refused.

Ollama base URL in config can use `http://host.docker.internal:11434` or a LAN IP set at compose-up. Skills that need to find Ollama on the LAN use `SCAN_SUBNET` and their own discovery (e.g. image-gen’s `discover-ollama.sh`).

---

## Tools and Skills

Built-in tools: `exec`, `read`, `write`, `edit`, `web_fetch`, `browser`, `memory_search`, `sessions_list`, `cron`, `image`, `message`. `web_fetch` is enabled; `web_search` is off by default (requires Brave/Perplexity API key). Weather uses the bundled skill (wttr.in via exec). Email via `workspace/scripts/send-email.sh` (Gmail SMTP) when env vars are set.

Custom skills live under `workspace/skills/{name}/`: `SKILL.md` (pipeline and instructions), `scripts/`, and optional knowledge files. They follow a pipeline pattern: classify → recall → execute → learn → respond, with silent fallback and structured logging. Examples: shopify-nexus (MCP product discovery), fashion-radar (trend intel), style-profile (per-customer style memory), restaurant-scout (reservations and deep links), image-gen (LAN Ollama or cloud), llm-manager (tier switching), daily-report. The template’s `AGENTS.md` enforces rules (e.g. never ask before searching, never expose failures, complete pipeline steps) so the model follows the skill flow reliably.

See `docs/TOOLS-AND-SKILLS.md` and `docs/MODEL-CHOICE.md` for details.

---

## Resource Budget (Guidance)

On a 32GB Mac you can run several agents (e.g. 4g each). On a Pi, one agent at 2g is typical. Adjust in `agent.conf`; the compose template uses `AGENT_MEM_LIMIT`, `AGENT_CPUS`, and `AGENT_SHM_SIZE` from there.

---

## Known Issues

- **Permission denied**: Containers run as UID 1000; ensure agent dirs (config-runtime, workspace, logs) are writable by that user. On Pi, if you run compose-up with sudo, the script chowns config-runtime for agents with HARDWARE_PROFILE=pi so the container can read it.
- **Ollama unreachable**: Ensure Ollama listens on the expected interface (e.g. `0.0.0.0` on the host for host.docker.internal). For LAN use, ensure the discovered host and port are reachable from the host that runs the container.
- **Gateway won’t start with bind: lan**: If OpenClaw requires a Control UI setting for non-loopback binding, add `"controlUi": { "dangerouslyAllowHostHeaderOriginFallback": true }` in the gateway section of `openclaw.json` (see `docs/RASPBERRY-PI-RUNBOOK.md`).
- **Crash loop**: Often a JSON or config error in `openclaw.json`; fix and restart.
- **Port conflict**: Each agent needs a unique port; `create-agent.sh` assigns the next free one; confirm with `list-agents.sh`.

We are still in an experimental phase; behavior and layout may evolve as we iterate.
