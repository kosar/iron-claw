# Shopify Nexus Elite: Powered by Chatsi

## The Platform: IronClaw

IronClaw is a hardened deployment framework built on top of [OpenClaw](https://openclaw.ai), the open-source LLM gateway. OpenClaw gives you a powerful autonomous agent with tool use, multi-channel messaging, persistent memory, and skill execution. IronClaw takes that foundation and wraps it in a deliberately restrictive security posture — because an agent that can execute shell commands, browse the web, read and write files, and talk to external APIs is exactly the kind of system that demands paranoia by default.

The core philosophy is simple: **assume the agent will encounter adversarial input, and constrain the blast radius before it happens.** Prompt injection, tool abuse, and credential exfiltration are not theoretical risks when your agent processes untrusted user messages from public channels and makes HTTP requests to arbitrary domains. IronClaw addresses this with layered containment rather than relying solely on the model's ability to resist manipulation.

At the container level, IronClaw runs as a non-root user (UID 1000) on a **read-only filesystem** with all Linux capabilities dropped and `no-new-privileges` enforced. The only writable paths are explicitly mounted volumes for configuration state, workspace, and logs — nothing else is mutable. The gateway port is bound to loopback only (`127.0.0.1:18789`) with token authentication, so the agent is never directly exposed to the network. Resource limits (12 GB RAM, 6 CPUs) cap runaway processes, and a Tini init process reaps orphaned child processes (particularly headless Chromium). Channel access is restricted to allowlists — both DMs and group messages are denied by default unless the sender is explicitly permitted in the configuration.

The configuration itself follows an immutable-source pattern: the host-side `config/` directory is the source of truth and is never written to by the container. A sync script copies it into `config-runtime/` at startup, and the container mounts only the runtime copy. This means a misbehaving agent cannot corrupt or backdoor its own configuration — the next restart resyncs from the clean source. Secrets are isolated in a `.env` file (gitignored) and injected as environment variables, never stored in config files that the agent can read via its own tools.

This is the environment Shopify Nexus runs inside. Every external HTTP request it makes, every shell command it executes, every file it writes to its knowledge base — all of it happens within these constraints. The skill itself adds an additional layer of input validation (SSRF checks on user-supplied domains) because defense in depth means validating at every boundary, not just the outer wall.

## What It Does

Shopify Nexus is a commerce intelligence skill for the IronClaw gateway. It gives any connected channel (Telegram, WhatsApp, HTTP) the ability to search product catalogs, retrieve pricing and availability, and answer store policy questions for **any public Shopify store** — by name or domain, on demand, with no pre-configuration required per store.

A user says "find me wool running shoes on allbirds.com" and gets back structured product results with prices, descriptions, and availability — optionally enriched by Chatsi Product Genius, an AI analysis layer that adds comparative recommendations and intelligent follow-up suggestions.

## How It Works

The skill operates as a three-stage pipeline:

**Stage 1 — Nexus Search (structured data retrieval)**
The primary interface is Shopify's MCP (Model Context Protocol) endpoint, a JSON-RPC 2.0 API exposed at `https://{domain}/api/mcp`. The skill performs a protocol handshake, discovers available tools (catalog search, product details, policy lookup), and executes the appropriate query. If MCP is unavailable for a given store, the skill falls back to Shopify's legacy `products.json` REST endpoint automatically.

A self-healing domain resolution chain handles real-world messiness: `.myshopify.com` variants, `www.` prefixes, common misspellings, and non-Shopify domains are all detected and corrected without user intervention.

**Stage 2 — Context Synthesis**
The top product results from Stage 1 are assembled into a structured payload enriched with the original query context. This payload is formatted for the Chatsi Product Genius API.

**Stage 3 — Chatsi Genius Analysis (optional enrichment)**
The synthesized payload is sent to the Chatsi Product Genius API, which returns AI-generated product analysis, comparative recommendations, and contextual follow-up questions. If Genius is offline or unconfigured, the skill degrades gracefully — the IronClaw agent performs its own analysis using the raw product data from Stage 1. The user always gets a thoughtful answer; Genius makes it better when available.

**Persistent Learning**
Every search writes structured observations to a knowledge file that persists across sessions and restarts. Store-specific learnings (which domains work, what query terms match each store's catalog taxonomy, whether MCP is supported) and cross-store patterns (what query structures produce the best results) accumulate over time. Each subsequent query to a previously-seen store is faster and more accurate than the last.

## Why We Built It

Shopify powers millions of storefronts, but there's no universal way to query them conversationally. Users want to ask natural questions — "what hiking shoes does Allbirds have under $150?" — and get direct answers, not a link to go browse.

The MCP protocol gives us structured, machine-readable access to any Shopify store's catalog without scraping HTML or requiring store-by-store API keys. Chatsi Genius adds an intelligence layer that transforms raw product listings into curated recommendations. Together, they turn a chat interface into a commerce search engine that works across the entire Shopify ecosystem.

The self-healing and learning systems exist because real-world commerce queries are messy. Domains are misspelled, stores use inconsistent terminology, and catalog structures vary wildly. Rather than failing on edge cases, the skill adapts and remembers.

## How to Use It

Shopify Nexus activates automatically when a user asks about products, pricing, availability, shipping, returns, or store policies for any Shopify store. No explicit invocation is required — the IronClaw agent recognizes commerce queries and routes them through the Nexus pipeline.

**Example queries:**
- "Search for running shoes on allbirds.com"
- "What's the return policy at gymshark.com?"
- "Find me a winter jacket under $200 on tentree.com"
- "Does allbirds have anything in wide sizes?"

**Requirements:**
- `curl` and `node` must be available in the container (both are included in the `ironclaw:2.0` image)
- Network access to public Shopify storefronts
- For Chatsi Genius enrichment: `CHATSI_API_URL`, `CHATSI_MERCHANT_ID`, and authentication credentials (`CHATSI_API_KEY` or OAuth2 client credentials) configured in `.env`
- Genius is optional — the skill is fully functional without it

**Monitoring:**
All skill activity is logged to `logs/nexus-search.log` as structured JSON, one event per line. Events cover the full pipeline: search initiation, domain validation, MCP discovery, query execution, result quality evaluation, Genius calls, and learning storage. Use this log to monitor search quality, identify failing stores, and track the skill's improvement over time.

## Running the IronClaw Environment

IronClaw is containerized and designed to go from clone to running gateway in a few steps. Here's what's involved.

**Prerequisites:**
- Docker Desktop (macOS/Windows) or Docker Engine (Linux)
- An OpenAI API key (for the primary model)
- A Telegram bot token and/or WhatsApp credentials (for messaging channels)

**1. Configure secrets**

Copy `.env.example` to `.env` and populate your API keys and tokens. This file is gitignored and is the only place secrets live. At minimum you need `OPENAI_API_KEY` and `OPENCLAW_GATEWAY_TOKEN` (an arbitrary string you choose for authenticating HTTP/WebSocket access to the gateway). Add `TELEGRAM_BOT_TOKEN` if you want Telegram, and the `CHATSI_*` variables if you have Chatsi Genius credentials.

**2. Review the configuration**

The gateway's behavior is defined in `config/openclaw.json`. This is where you'll find:
- **Model stack** — primary and fallback model providers, pricing, context windows
- **Agent defaults** — timeouts, concurrency limits, heartbeat schedule
- **Gateway settings** — port, auth mode, HTTP endpoint toggles
- **Channel configuration** — which messaging channels are enabled, allowlists for permitted senders, group policies
- **Tool and skill toggles** — which built-in tools (web fetch, browser, exec) and custom skills (like Shopify Nexus) are active

The security hardening lives in `docker-compose.yml`: read-only filesystem, capability drops, non-root user, resource limits, loopback-only port binding, and volume mounts. The `Dockerfile` defines the image build — it starts from `node:22-bookworm-slim`, installs system dependencies (Chromium, ffmpeg, ripgrep), and runs the official OpenClaw installer as a non-root user.

**3. Start the gateway**

```bash
./scripts/compose-up.sh -d
```

This script syncs `config/` into `config-runtime/` (preserving session state and container-written files from previous runs), prepends agent guidelines from `workspace/AGENTS.md`, copies custom skills from `workspace/skills/`, and then runs `docker compose up`. On first run it does a full copy; on subsequent runs it does an incremental sync so session history, agent memory, and channel credentials survive restarts.

For a clean-slate restart that wipes runtime state:

```bash
./scripts/compose-up.sh --fresh -d
```

**4. Verify**

```bash
docker ps                        # confirm container is healthy
./scripts/test-gateway-http.sh   # hit the HTTP endpoint
./scripts/watch-logs.sh          # live tail of agent run lifecycle
```

The gateway dashboard is available at `http://localhost:18789` — see the project README for device pairing instructions.

**5. Shopify Nexus is ready**

Once the gateway is running, Shopify Nexus is active. No additional setup is required for the core MCP-based product search. Send a message through any connected channel asking about products at a Shopify store and the skill activates automatically. Chatsi Genius enrichment becomes available once the `CHATSI_*` credentials in `.env` are populated.
