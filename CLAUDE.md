# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**IronClaw** is a factory system for spinning up hardened OpenClaw agent deployments on Docker. Each agent gets its own personality, skills, channels, secrets, and container while sharing the base Docker image and operational scripts. Runs on any Docker host (e.g. Mac, Linux, Raspberry Pi).

- **Container image:** `ironclaw:2.0` (custom source build via `openclaw.ai/install.sh`, Node.js, runs `gateway` command)
- **Agents live in:** `agents/{name}/` — each is a fully self-contained OpenClaw deployment
- **Current agents:** `sample-agent` (runnable example); create more with `./scripts/create-agent.sh <name>`. For a Pi-style agent, see [docs/RECREATING-PIBOT.md](docs/RECREATING-PIBOT.md).

## Common Commands

```bash
# Create a new agent from template
./scripts/create-agent.sh mybot admin@example.com

# Start/restart an agent (syncs config/ → config-runtime/, then docker compose up)
./scripts/compose-up.sh sample-agent -d

# Full reset of an agent's runtime state
./scripts/compose-up.sh sample-agent --fresh -d

# Stop an agent
docker compose -p sample-agent down

# Nuke an agent (wipes memory/state)
docker compose -p sample-agent down --volumes

# Start all agents
./scripts/compose-up-all.sh

# List all agents with status
./scripts/list-agents.sh

# Check container health
docker ps

# Live log monitoring (run lifecycle + costs)
./scripts/watch-logs.sh sample-agent

# Last N log lines (pretty-printed with jq)
./scripts/check-logs.sh sample-agent 50
./scripts/check-logs.sh sample-agent follow

# Failure analysis
./scripts/check-failures.sh sample-agent
./scripts/check-failures.sh sample-agent --replies

# Advanced log analysis
./scripts/analyze-logs.sh sample-agent --days 7 --category auth

# Token cost summary
./scripts/usage-summary.sh sample-agent
./scripts/usage-summary.sh sample-agent <sessionId>

# Internal per-run learning feedback (owner-only)
tail -f agents/sample-agent/logs/learning-bridge.log
cat agents/sample-agent/logs/learning/latest-feedback.txt

# Test gateway endpoints
./scripts/test-gateway-http.sh sample-agent

# Host dashboard (Pi / host-side web UI: agents, bridges, gateway, logs, failures, usage)
./scripts/start-dashboard.sh
# → Open http://<host>:18795 (override port with IRONCLAW_DASHBOARD_PORT)
```

## Architecture

### Multi-Agent Layout

```
ironclaw/                           # repo root = ironclaw-core
  Dockerfile                        # shared image
  scripts/                          # operational scripts (all take agent-name as $1)
    lib.sh                          # shared agent resolution helper
    docker-compose.yml.tmpl         # compose template (envsubst'd per agent)
    compose-up.sh                   # start an agent
    create-agent.sh                 # scaffold a new agent
    list-agents.sh                  # show all agents + status
    compose-up-all.sh               # start all agents
    watch-logs.sh, check-logs.sh, etc.  # all parameterized via lib.sh
  agents/
    template/                       # full OpenClaw-defaults skeleton for new agents
    sample-agent/                   # runnable example agent
      agent.conf                    # AGENT_NAME, PORT, container, resources
      .env                          # secrets (gitignored)
      config/                       # OpenClaw config (host-side, immutable)
      workspace/                    # agent guidelines, skills, personality
      config-runtime/               # generated at runtime (gitignored)
      logs/                         # per-agent logs (gitignored)
      docker-compose.yml            # generated from template (gitignored)
```

### Per-Agent Config (`agent.conf`)

Each agent has an `agent.conf` that defines deployment parameters:
- `AGENT_NAME` — directory name under agents/
- `AGENT_PORT` — unique gateway port
- `AGENT_CONTAINER` — Docker container name (`{name}_secure`)
- `AGENT_MEM_LIMIT` — RAM limit
- `AGENT_CPUS` — CPU limit
- `AGENT_SHM_SIZE` — shared memory for Chromium
- `EXEC_HOST` — optional; set to `gateway` for agents that run exec in the same container (e.g. Raspberry Pi, no Docker sandbox). Compose-up injects this so exec runs in the gateway container.

### Naming: host, agent, channel handle

Three distinct named entities (especially for agents that run on multiple hosts, e.g. Pi + Mac):

1. **Host** — The physical machine (Raspberry Pi, Mac, etc.). Hostname on the LAN is mainly for the operator; the agent rarely needs it.
2. **Agent name** — The repo-level name in `agents/{name}/` (e.g. sample-agent, mybot). One per folder: shared personality, skills, defaults. Avoid putting host- or instance-specific content in shared workspace files (e.g. AGENTS.md); use operator docs or per-host config instead.
3. **Channel handle** — How users reach a given instance on a channel (e.g. @your_bot on Telegram). See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and [docs/RECREATING-PIBOT.md](docs/RECREATING-PIBOT.md) for allowlists and pairing.

For Pi-style agents with identity/display rules, see [docs/RECREATING-PIBOT.md](docs/RECREATING-PIBOT.md) and [docs/RASPBERRY-PI-RUNBOOK.md](docs/RASPBERRY-PI-RUNBOOK.md).

### Config Separation

The container never writes to `config/`. The `compose-up.sh` script syncs `config/` into `config-runtime/`, and the container mounts `config-runtime/` as the OpenClaw home directory. This keeps host-side config immutable. The sync preserves sessions and container-written files (like `models.json`, `memory/main.sqlite`) unless `--fresh` is used.

Host `workspace/AGENTS.md` is prepended into `config-runtime/workspace/AGENTS.md` by `compose-up.sh`. Host `workspace/skills/` and `workspace/scripts/` are rsynced into `config-runtime/workspace/`.

**Exec approval self-heal:** On every run, `compose-up.sh` enforces `tools.exec.security: "full"` and `ask: "off"` in config-runtime. Agents with **`EXEC_HOST=gateway`** in `agent.conf` get `tools.exec.host: "gateway"` and `agents.defaults.sandbox.mode: "off"` (exec runs in the same container; used e.g. on Raspberry Pi where there is no Docker sandbox). Other agents get `host: "sandbox"` so exec would run in a separate Docker container when available.

### Volume Mounts (per agent)

| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| `agents/{name}/config-runtime/` | OpenClaw home (see `scripts/docker-compose.yml.tmpl`) | Gateway config + agent state (rw) |
| `agents/{name}/workspace/` | OpenClaw home `/workspace` | Agent guidelines + skills (rw) |
| `agents/{name}/logs/` | `/tmp/openclaw` and `/tmp/openclaw-1000` | App logs (rw) |

### Security Hardening

All containers: UID `1000:1000`, read-only filesystem (rw only on mounted volumes), all capabilities dropped, no-new-privileges, tmpfs /tmp, init (tini). Resource limits per agent.conf.

### Model Stack

- **Primary:** `openai/gpt-5-mini` ($0.25/$2.00 per 1M tokens input/output, 400K context, 128K max output, reasoning: true). GPT-5 family recommended for tool-enabled bots due to prompt injection resistance.
- **Fallback:** `ollama/qwen3:8b` (local, free, via `host.docker.internal:11434`)
- Other local models available: `qwen3:14b`, `qwen2.5-coder:14b`, `llama3.2:latest`
- Failover triggers on auth failures, rate limits, and timeouts only (not connection refused)

### Logging

Two log sources per agent:
- **Docker stdout** (`docker logs {name}_secure`): startup, Telegram auth, warnings
- **App log** (`agents/{name}/logs/openclaw-YYYY-MM-DD.log`): JSON-per-line, daily rotation, contains run lifecycle (start/done), session state, model used, durations, token costs
- **Learning feedback logs** (`agents/{name}/logs/learning/`): owner-only run-quality records generated after each `embedded run done`

Run lifecycle in app logs: `lane enqueue` → `embedded run start` → `session state processing` → `run registered` → agent/tool calls → `embedded run done` → `lane task done`

**Log format compatibility:** OpenClaw file logs are one JSON object per line. The human-readable message may appear under different keys depending on gateway/logger version: numeric keys `"0"`, `"1"`, `"2"` (legacy) or Pino-style `msg` / `message`. Our logging scripts (`watch-logs.sh`, `check-logs.sh`, `piglow-log-bridge.sh`, `analyze-logs.sh`, `daily-report.sh`) try all of these so they keep working across OpenClaw upgrades. When adding or changing log parsing, use the same multi-key extraction (e.g. `.["msg"] // .["message"] // .["1"] // .["0"]`).

**Run lifecycle in watch-logs:** The gateway logs "embedded run start", "embedded run tool start", etc. at **DEBUG** level. For `watch-logs.sh` to show run/tool/LLM/cost lines (not just "SENT" and errors), set `logging.level` to `"debug"` in `agents/{name}/config/openclaw.json`. Restart the agent after changing. The template and agents in this repo include `"logging": { "level": "debug" }` by default.

Built-in post-run learning loop:
- `compose-up.sh <agent> -d` auto-starts `scripts/learning-log-bridge.sh` (unless `IRONCLAW_DISABLE_LEARNING_BRIDGE=1`)
- bridge triggers `scripts/learning-feedback.py` on each `embedded run done`
- feedback is stored in `agents/{name}/logs/learning/feedback-YYYY-MM-DD.jsonl` plus `quality-timeseries.jsonl`
- evaluator tracks historical deltas and feedback uptake (improved vs not_improved after coaching)
- email modes:
  - `LEARNING_FEEDBACK_EMAIL_MODE=immediate` (per run)
  - `LEARNING_FEEDBACK_EMAIL_MODE=digest` with `LEARNING_FEEDBACK_DIGEST_MIN_RUNS` / `LEARNING_FEEDBACK_DIGEST_MINUTES`
  - `LEARNING_FEEDBACK_EMAIL_MODE=off`
- this feedback is strictly internal and must never be shown to end users

## Key Files

| File | Purpose |
|------|---------|
| `agents/{name}/config/openclaw.json` | Main gateway config: models, agents, channels, tools, auth |
| `agents/{name}/config/agents/main/agent/models.json` | Provider pricing (cost per 1M tokens) |
| `agents/{name}/.env` | Secrets (gitignored): `OPENCLAW_GATEWAY_TOKEN`, `OPENAI_API_KEY`, `TELEGRAM_BOT_TOKEN`, etc. |
| `agents/{name}/agent.conf` | Deployment config: port, resources, container name |
| `agents/{name}/workspace/AGENTS.md` | Agent behavior guidelines |
| `agents/{name}/workspace/SOUL.md` | Agent personality |
| `agents/{name}/workspace/skills/` | Custom skill definitions |
| `scripts/lib.sh` | Shared agent resolution (sourced by all scripts) |
| `scripts/docker-compose.yml.tmpl` | Compose template (envsubst'd per agent) |
| `agents/template/` | Full OpenClaw-defaults skeleton for new agents |
| `dashboard/` | Host dashboard: server (port 18795), static UI, probe scripts; start with `./scripts/start-dashboard.sh` or systemd `ironclaw-dashboard.service` |

## Configuration Workflow

1. Edit files in `agents/{name}/config/` (never `config-runtime/`)
2. Run `./scripts/compose-up.sh {name} -d` to sync and restart
3. Secrets go in `agents/{name}/.env`, referenced as `${VAR_NAME}` in config
4. New API keys: add to `agents/{name}/.env`, restart

## PROTECTED SETTINGS — Do Not Remove or Change Without Understanding the Impact

The following settings have caused major regressions when removed by AI assistants. Each one looks "redundant" or "cleanable" but is load-bearing. **Read the explanation before touching.**

### `"bind": "lan"` in `gateway` — DO NOT REMOVE

```json
"gateway": {
  "bind": "lan",   ← THIS IS REQUIRED. DO NOT REMOVE.
  ...
}
```

**Why it exists:** Without `"bind": "lan"`, OpenClaw binds to `127.0.0.1` *inside the container* (loopback only). Docker's port mapping cannot forward external connections to a container-internal loopback — TCP handshake succeeds but all data returns "Empty reply from server". This silently breaks:
- **BlueBubbles/iMessage** — webhooks from the BlueBubbles server never arrive
- **Any external HTTP client** — appears connected but gets no response
- The `docker ps` healthcheck still shows "healthy" (it only tests TCP, not protocol)

**Confirmed in Dockerfile comment:** `# Run the gateway server. Binding is controlled by openclaw.json (bind: "lan").`

**The trap:** OpenClaw CLI commands run *inside* the container will refuse with a security error (`SECURITY ERROR: Gateway URL "ws://172.x.x.x:18789" uses plaintext ws:// to a non-loopback address`). This looks like `bind: lan` is breaking something. It is NOT — that error is the CLI protecting against unencrypted external connections. The channels (BlueBubbles, Telegram) are unaffected and work correctly. If you need to run CLI commands inside the container, use `--gateway ws://127.0.0.1:18789` to override.

**History:** Removed in commit `d33043d` ("fixes"). Took hours to diagnose because the container appeared healthy. Caused all iMessage delivery to silently fail.

### `"mode": "local"` in `gateway` — DO NOT CHANGE

```json
"gateway": {
  "mode": "local",   ← Required. The gateway won't start without it.
  ...
}
```

OpenClaw requires `gateway.mode=local` to start (see `--allow-unconfigured` flag in `openclaw gateway --help`). This has been `"local"` since the first commit. Do not change it.

### `gateway.controlUi` when `bind` is `"lan"` — DO NOT REMOVE

When `gateway.bind` is `"lan"`, OpenClaw requires a Control UI origin policy or the gateway **refuses to start**. You will see:

`Gateway failed to start: Error: non-loopback Control UI requires gateway.controlUi.allowedOrigins (set explicit origins), or set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback=true`

**Impact of removing it:** The gateway never starts. The container may show "healthy" (TCP only), but the app exits; Telegram, webhooks, and all channel traffic get no response. Do not remove or "clean up" `controlUi` on LAN-bound agents. Use either explicit `allowedOrigins` or `dangerouslyAllowHostHeaderOriginFallback: true` (see `docs/RASPBERRY-PI-RUNBOOK.md`). Test gateway and channels after any change.

**What this setting does NOT affect:** `controlUi` only affects which browser origins can talk to the gateway's Control UI. It does **not** affect outbound requests from the agent (e.g. PiGlow, camera, RFID, host scripts). If PiGlow or other host bridges stop working after a config change, the cause is elsewhere: host service running, `host.docker.internal` / Docker networking, or (for PiGlow) `PIGLOW_SIGNAL_URL` in the agent's `.env` to point at the host (e.g. `http://<host-ip>:18793/signal`) if needed.

### After gateway or openclaw.json changes — verify all bridges

Fixing one thing (e.g. gateway start) can mask or coincide with other breakage. **After any change to gateway or agent config, run a short verification** so you don't assume one fix didn't break others:

1. **Gateway:** `./scripts/test-gateway-http.sh <agent>` — must return JSON, not "Connection reset by peer".
2. **Channels:** Send a test message (Telegram, etc.) and confirm the agent replies.
3. **Host bridges (Pi-style agents):** If the agent uses PiGlow, camera, or log bridge, confirm they still work (e.g. PiGlow service on host, `curl http://127.0.0.1:18793/health`; from container, `host.docker.internal:18793` is used by the skill — if that fails, set `PIGLOW_SIGNAL_URL=http://<host-ip>:18793/signal` in the agent's `.env` and restart).

---

## Common Pitfalls — Read Before Touching Config or Skills

### Pi-style agents: Do NOT set `tools.exec.host` to `"node"`
Agents that run with **nodes and canvas denied** (`tools.deny: ["nodes", "canvas"]`) must not have `tools.exec.host` set to `"node"`. If set to `"node"`, OpenClaw only runs exec when a "node" is paired; with no nodes, **every exec (including ir-blast, piglow-signal, camera scripts) is blocked**. Leave exec so it runs in the container (gateway). IR, PiGlow, and camera skills need exec in the container; host access is via device passthrough or HTTP to the host, not via a paired node.

### Why exec "suddenly" became blocked (EXEC_HOST=gateway agents)
If an agent that should run exec in the container one day reported "exec blocked" or "sandbox runtime unavailable" after a restart, the cause was **compose-up.sh** overwriting config-runtime with `tools.exec.host = "sandbox"` for every agent. The script now enforces **per-agent** values — any agent with **`EXEC_HOST=gateway`** in `agent.conf` gets `host: "gateway"` and `agents.defaults.sandbox.mode: "off"`; other agents get `host: "sandbox"`. Set `EXEC_HOST=gateway` in `agent.conf` for Pi-style agents, then run `./scripts/compose-up.sh <agent> -d` to apply.
pibot’s runtime config reverted to sandbox even though the container has no Docker. The script now enforces **per-agent** values: any agent with **`EXEC_HOST=gateway`** in `agent.conf` gets `host: "gateway"` and `agents.defaults.sandbox.mode: "off"`; other agents get `host: "sandbox"`. Set `EXEC_HOST=gateway` in `agent.conf` for Pi-style agents, then run `./scripts/compose-up.sh <agent> -d` to apply.

### NEVER use `jq` in skill scripts — use `python3` or `node` instead

`jq` is not installed in the agent Docker image. Any skill script that calls `jq` will show as **blocked** in the admin panel with `Missing: bin:jq`. This applies to all scripts in `workspace/skills/*/scripts/`.

**Pattern for JSON reads:**
```bash
VALUE=$(python3 -c "import json,sys; print(json.load(open('$FILE'))['key'])" 2>/dev/null || echo "default")
```

**Pattern for JSON writes (atomic):**
```bash
python3 -c "
import json, os
with open('$FILE') as f: d = json.load(f)
d['key'] = '$VALUE'
tmp = '$FILE.tmp'
with open(tmp, 'w') as f: json.dump(d, f, indent=2)
os.replace(tmp, '$FILE')
"
```

**SKILL.md requires block** — use `bins: ["bash", "python3"]`, never `["jq"]`.

Available in all agent containers: `bash`, `python3`, `node`, `curl`, `openssl`. NOT available: `jq`, `yq`, `xmllint`, `bc`.

### NEVER add unsupported keys to `openclaw.json`
OpenClaw validates its config schema and logs `Unrecognized key` warnings for any unknown field. These warnings look alarming but the real fix is **always to update the script/skill, not the config**. Examples of keys that do NOT exist in OpenClaw's schema and must never be added:
- `agents.defaults.report` — a Python script reading config doesn't need a new schema key; read from existing keys (e.g. `heartbeat.model`) or use a hardcoded default.
- `models.providers.*.models[].tier` — `tier` is not an OpenClaw model field. `scripts/model-profiles/openai-all.json` is a **reference catalog only**; never merge it into `openclaw.json`.

### NEVER modify `openclaw.json` to fix a skill/script path issue
If a skill script can't find a file, **fix the path logic in the script**. The config schema is fixed by OpenClaw; adding custom keys to work around a broken script path is wrong and will generate validation warnings on every restart.

### `reasoning` flags — must match model type
- `reasoning: true` — only for genuine reasoning/thinking models (`o3`, `o4-mini`, explicit `-thinking` variants)
- `reasoning: false` — required for everything else: `gpt-5-mini`, `gpt-5-nano`, `gpt-4o`, `gpt-4o-mini`, all Ollama models
- Setting `reasoning: true` on a non-thinking model causes session replay failures → 400 errors
- Note: `gpt-5-mini` is inherently a reasoning model and still emits `thinkingSignature` even with `false`; the flag reduces but doesn't eliminate this

### Skill scripts run inside the container — paths differ from the host
Scripts invoked via `exec` run **inside the container**, not on the host. Key paths inside the container (exact mount paths are in `scripts/docker-compose.yml.tmpl`):

| What | Where (in container) | Notes |
|------|----------------------|-------|
| OpenClaw config | OpenClaw home `openclaw.json` | Not under `agents/main/config/` |
| App logs | `/tmp/openclaw/openclaw-YYYY-MM-DD.log` | Daily rotation |
| Gateway token | `$OPENCLAW_GATEWAY_TOKEN` env var | From `.env` via compose |
| Workspace | OpenClaw home `workspace/` | Mounted from host `agents/{name}/workspace/` |
| model_switches.log | `/tmp/openclaw/model_switches.log` | Written by switch-tier.sh |
| Sessions | **SQLite only** (`memory/main.sqlite`) | OpenClaw does not write JSONL session files |

Skill scripts should use paths relative to the workspace (e.g. `workspace/skills/<name>/scripts/...`) or the OpenClaw home; avoid hard-coding the home directory path so the repo stays portable.

## Creating a New Agent

```bash
./scripts/create-agent.sh mybot admin@example.com
# → creates agents/mybot/ with full OpenClaw defaults
# → auto-assigns next available port
# → prints setup checklist
```

Then: fill in `.env`, customize personality files in `workspace/`, configure channels, and start.

## Tools and Skills

Built-in tools include: `exec`, `read`, `write`, `edit`, `web_fetch`, `browser`, `memory_search`, `sessions_list`, `cron`, `image`, `message`. `web_fetch` is **enabled** (no API key needed). `web_search` is **disabled** (needs Brave/Perplexity API key). `browser` uses Chromium installed in the image (works with Playwright). Python `playwright` and `playwright-stealth` are also installed for skills that need robust browser automation (e.g. ProductWatcher’s browser_automation provider for JS-heavy and bot-protected sites).

Weather uses the bundled skill with `curl -s "wttr.in/<CITY>?format=3"` via exec (no API key needed).

Email capability via `workspace/scripts/send-email.sh` (Gmail SMTP via curl, requires `SMTP_FROM_EMAIL` and `GMAIL_APP_PASSWORD` in `.env`).

### Custom Skills

Custom skills live in `workspace/skills/{skill-name}/` and follow a pipeline pattern:
- `SKILL.md` — multi-step pipeline instructions (classify → recall → execute → learn → respond)
- `scripts/` — shell scripts for logging, MCP clients, data fetching
- Knowledge files (e.g., `nexus-knowledge.md`, `trend-intelligence.md`) — persistent learning that improves over time

Existing custom skills (template and sample-agent):
- **shopify-nexus** — Ported from reference. Shopify MCP product/policy search, products.json fallback, optional Chatsi Genius; SSRF checks, nexus-knowledge.md. Disabled by default; enable in `skills.entries`.
- **fashion-radar** — Ported from reference. Trend intelligence from fashion editorial; trend-intelligence.md, fashion-log.sh. Disabled by default.
- **style-profile** — Ported from reference. Per-customer style memory (sizes, preferences, brands); customer-profiles.md, profile-manager.sh. Disabled by default.
- **llm-manager** — Ported from reference. Runtime model tier switching (tiers.json, switch-tier.sh); logs to `/tmp/openclaw/model_switches.log`; session-scoped. Disabled by default.
- **productwatcher** — Product/watch lists; Shopify MCP provider, brave_search, direct_scrape, browser_automation.
- **restaurant-scout**, **daily-report**, **send-email**, **weather**, **image-gen**, **image-vision**, **pdf-reader**, Pi skills (**ir-blast**, **piglow-signal**, **piface-display**, **camera-capture**, **rfid-reader**), **four-agreements** — See `docs/TOOLS-AND-SKILLS.md`.

### Template Behavioral Enforcement

The template `AGENTS.md` (`agents/template/workspace/AGENTS.md`) includes 6 mandatory rules that all agents inherit:
1. **Never ask before searching** — search with reasonable defaults, including brand-name queries (always try the brand's official store first)
2. **Never expose failures** — silent fallback chain (primary → retry → alternative → web → "not found")
3. **Never mention internals** — no tool names, API errors, or process explanations in user-facing replies
4. **Complete every pipeline step** — post-search learning and logging are mandatory, not optional
5. **Use custom skills over built-in tools** — custom skills have domain pipelines and persistent knowledge
6. **Offer, don't ask** — suggest next steps as offers, not blocking questions

These rules use enforcement language ("MANDATORY", "FORBIDDEN", forbidden phrases list) because GPT-5-mini requires explicit enforcement to reliably follow multi-step skill pipelines.

See `docs/TOOLS-AND-SKILLS.md` for the full tool/skill reference and `docs/MODEL-CHOICE.md` for model selection guidance.

## Resource budget (example: 32GB host)

| Agents | RAM each | Total RAM | Notes |
|--------|----------|-----------|-------|
| 2 (e.g. sample-agent + mybot) | 4g + 4g | 8g | Typical |
| 3 | 8g + 4g + 4g | 16g | Comfortable |
| 6 | 4g each | 24g | Leaves headroom for host + Ollama |
| 8+ | 2-3g each | 20-24g | Lightweight agents |
