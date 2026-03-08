# Tools and skills for OpenClaw agents

This project runs the OpenClaw gateway in Docker. Agents get **built-in tools** (from the OpenClaw runtime) and can use **skills** (in `workspace/skills/` or bundled with the image). Below: skills in this repo, then OpenClaw’s built-in tools and image skills.

---

## Skills in this repo (`workspace/skills/`)

These live under `agents/template/workspace/skills/` and `agents/sample-agent/workspace/skills/`. Enable or disable in `config/openclaw.json` under `skills.entries`.

| Skill | Description |
|-------|-------------|
| **productwatcher** | Product/watch lists; Shopify MCP provider, brave_search, direct_scrape, browser_automation. See `docs/shopify-nexus/` for Shopify context. |
| **shopify-nexus** | Optional built-in (reference). Shopify product/policy search via MCP + products.json fallback; optional Chatsi Genius. SSRF checks, nexus-knowledge.md learning. Disabled by default. |
| **fashion-radar** | Optional built-in (reference). Trend intelligence from fashion editorial; trend-intelligence.md, fashion-log.sh. Disabled by default. |
| **style-profile** | Optional built-in (reference). Per-customer style memory (sizes, preferences, brands); customer-profiles.md, profile-manager.sh. Disabled by default. |
| **llm-manager** | Optional built-in (reference). Runtime model tier switching (tiers.json, switch-tier.sh); writes to `model_switches.log`. Disabled by default. |
| **restaurant-scout** | Reservations, deep links (Resy, OpenTable, etc.). Needs web search. Disabled by default. |
| **daily-report** | Daily activity reports from logs; AI summary. Run as `python3 skills/daily-report/daily-report.py main`. |
| **send-email**, **weather**, **image-gen**, **image-vision**, **pdf-reader**, **ir-blast**, **piglow-signal**, **piface-display**, **camera-capture**, **rfid-reader**, **four-agreements** | See each skill’s SKILL.md under `workspace/skills/`. |

---

## What tools are available by default

OpenClaw’s built-in **tools** (no extra install) include:

| Tool / group | Description | Notes |
|--------------|-------------|--------|
| **exec** / **process** | Run shell commands, background jobs | `group:runtime` |
| **read** / **write** / **edit** / **apply_patch** | File operations in workspace | `group:fs` |
| **web_search** | Web search (Brave or Perplexity) | Needs `BRAVE_API_KEY` or Perplexity config |
| **web_fetch** | Fetch URL and extract content | No key required |
| **browser** | Managed browser (snapshot, click, type, etc.) | Enabled by default |
| **memory_search** / **memory_get** | Conversation memory | `group:memory` |
| **sessions_list** / **sessions_history** / **sessions_send** / **session_status** | Cross-session | `group:sessions` |
| **message** | Send/react in Telegram, Slack, etc. | `group:messaging` |
| **cron** / **gateway** | Cron jobs, gateway restart | `group:automation` |
| **nodes** / **canvas** | Paired devices, canvas UI | If nodes configured |
| **image** | Image analysis | If image model configured |

Your config has `"commands": { "native": "auto", "nativeSkills": "auto" }`, so **native skills** shipped with the image are also enabled.

---

## Bundled skills in this image (`ghcr.io/phioranex/openclaw-docker:latest`)

The following was taken from the **currently running container** (skills under `/app/skills`). Eligibility depends on required binaries and env vars; skills that need a CLI or API key are only active when that dependency is satisfied.

### Skill list (bundled in image)

| Skill | Description / requirement |
|-------|----------------------------|
| **1password** | 1Password CLI (`op`) |
| **apple-notes** | Apple Notes via `memo` (macOS) |
| **apple-reminders** | Apple Reminders via `remindctl` (macOS) |
| **bear-notes** | Bear notes via `grizzly` (macOS) |
| **bird** | X/Twitter CLI |
| **blogwatcher** | RSS/Atom feed monitoring |
| **blucli** | BluOS speakers (`blu`) |
| **bluebubbles** | BlueBubbles plugin |
| **camsnap** | RTSP/ONVIF camera frames |
| **canvas** | Display HTML on nodes |
| **clawdhub** | Install/update skills from ClawHub (`clawdhub` CLI) |
| **coding-agent** | Codex / Claude Code / OpenCode / Pi |
| **discord** | Discord (requires `channels.discord` in config) |
| **eightctl** | Eight Sleep pods |
| **food-order** | Foodora reorder via `ordercli` |
| **gemini** | Gemini CLI |
| **gifgrep** | GIF search/download |
| **github** | GitHub integration |
| **gog** | GOG CLI |
| **goplaces** | Places/location |
| **himalaya** | Email (Himalaya CLI) |
| **imsg** | iMessage (macOS) |
| **local-places** | Local places |
| **mcporter** | — |
| **model-usage** | Model usage stats |
| **nano-banana-pro** | Image gen (Gemini); needs `GEMINI_API_KEY` |
| **nano-pdf** | PDF handling |
| **notion** | Notion |
| **obsidian** | Obsidian notes |
| **openai-image-gen** | OpenAI image generation |
| **openai-whisper** / **openai-whisper-api** | Whisper transcription |
| **openhue** | Philips Hue |
| **oracle** | — |
| **ordercli** | Order CLI |
| **peekaboo** | — |
| **sag** | ElevenLabs TTS; needs `ELEVENLABS_API_KEY` (or `SAG_API_KEY`) and `sag` binary |
| **session-logs** | Session logs |
| **sherpa-onnx-tts** | Sherpa ONNX TTS |
| **skill-creator** | Create new skills |
| **slack** | Slack (requires Slack channel config) |
| **songsee** | — |
| **sonoscli** | Sonos |
| **spotify-player** | Spotify |
| **summarize** | Summarization (needs `summarize` CLI) |
| **things-mac** | Things 3 (macOS) |
| **tmux** | Tmux |
| **trello** | Trello |
| **video-frames** | Video frame extraction |
| **voice-call** | Voice calls |
| **wacli** | — |
| **weather** | **Current weather and forecasts** (see below) |

### Weather skill in this image — no API key needed

The bundled **weather** skill uses two free services and **does not use OpenWeatherMap or any API key**:

- **wttr.in** — compact or full text forecasts via `curl` (e.g. `curl -s "wttr.in/London?format=3"`).
- **Open-Meteo** — JSON forecast API (no key).

**Requirement:** only `curl` (already in the container). The agent can answer weather questions as soon as the skill is eligible; you do **not** need to set `OPENWEATHERMAP_API_KEY` for this skill.

If the agent says it can’t get weather, check that the skill is not disabled in config and that logs don’t show a missing binary (e.g. `curl`).

**OpenWeatherMap:** `OPENWEATHERMAP_API_KEY` is **not** used by this image’s weather skill. Set it only if you install a *different* weather skill (e.g. from ClawHub) that explicitly requires OpenWeatherMap.

---

## How to add more tools/skills

### 1. Built-in web search

To use **web_search**, set a search provider and API key:

- **Brave (default):** get a key from [Brave Search API](https://brave.com/search/api/) and set `BRAVE_API_KEY` in `.env` (or in config under `tools.web.search.apiKey`).
- **Perplexity:** set `OPENROUTER_API_KEY` or `PERPLEXITY_API_KEY` and in config set `tools.web.search.provider` to `"perplexity"` (see [Web tools](https://docs.openclaw.ai/tools/web)).

Add the same variable to `.env` and ensure the container receives it (see “Passing env vars into the container” below).

### 2. Skills (e.g. weather, email)

- **Bundled skills**  
  The Docker image may already include skills (e.g. weather). They are gated by env: if the skill expects `OPENWEATHERMAP_API_KEY`, set it in `.env` and pass it into the container; the skill then becomes eligible.

- **Installing more skills**  
  OpenClaw can load skills from:
  - `~/.openclaw/skills` (in the container: `/home/node/.openclaw/skills`)
  - `<workspace>/skills` (your workspace is mounted)

  To install from [ClawHub](https://clawhub.com) you typically run on a host where the OpenClaw CLI is installed, then copy the skill into a folder that is mounted or baked into the image. For a Docker-only setup, you’d either:
  - add a volume or copy step that provides `skills` under the config/workspace path the container uses, or  
  - use an image that already includes the skill.

- **Config overrides**  
  In `config/openclaw.json` you can enable/disable or configure skills under `skills.entries`:

  ```json
  "skills": {
    "entries": {
      "weather-cli": {
        "enabled": true,
        "apiKey": "${OPENWEATHERMAP_API_KEY}"
      }
    }
  }
  ```

  Skill names and keys depend on the skill (e.g. `weathercli` vs `weather-cli`). If the image bundles a weather skill, check its `SKILL.md` for `metadata.openclaw.primaryEnv` or required env.

---

## Adding weather with OPENWEATHERMAP_API_KEY

**For this image:** the bundled **weather** skill uses wttr.in and Open-Meteo and **does not need** `OPENWEATHERMAP_API_KEY`. See the section **Bundled skills in this image** above.

Use the steps below only if you install a **different** weather skill (e.g. from ClawHub) that requires OpenWeatherMap:

### 1. Get an API key

- Sign up at [OpenWeatherMap](https://openweathermap.org/api) and create an API key (free tier is enough for personal use).

### 2. Put the key in `.env`

In the project root, in `.env` (create from `.env.example` if needed):

```bash
# Optional — for weather (and any skill that uses this env name)
OPENWEATHERMAP_API_KEY=your-key-here
```

Do **not** commit `.env`; it is gitignored.

### 3. Pass it into the container

The repo uses `env_file: .env` in `docker-compose.yml`, so **all variables defined in `.env` are passed into the container**. No need to list each one in `environment:` unless you want to override. So adding `OPENWEATHERMAP_API_KEY` to `.env` is enough.

If your image or skill expects a different name (e.g. `OPENWEATHER_API_KEY`), add that variable to `.env` as well and, if needed, in `docker-compose.yml` under `environment:` for clarity.

### 4. Restart the gateway

```bash
./scripts/compose-up.sh -d
# or
docker compose down && docker compose up -d
```

After restart, the gateway (and any skill that checks for `OPENWEATHERMAP_API_KEY`) will see the variable. If the image bundles a weather skill that uses this env, the agent should stop saying “missing API key” for weather and be able to answer weather questions.

### 5. If the agent still says “no weather” or “missing key”

- Check logs: `./scripts/watch-logs.sh` or `./scripts/check-failures.sh` for auth/tool errors.
- Confirm the container has the key (never log the full key):
  ```bash
  docker exec openclaw_secure node -e "const k=process.env.OPENWEATHERMAP_API_KEY||''; console.log('set:', !!k.length)"
  ```
- Confirm the exact env name the skill expects (image docs or skill’s `SKILL.md`: `requires.env` / `primaryEnv`). If it’s different, add that name to `.env` and restart.

---

## Bot says “cannot complete … missing API key”

That message usually comes from the **web_search** tool, not weather. When the agent tries to search the web and no search API key is set, the tool returns an error and the bot tells you about the missing key.

You can either **add a search provider** or **disable web search** (no key, no cost).

---

### Option A: Use Perplexity for web search (pay-as-you-go)

Brave Search no longer has a free tier. OpenClaw can use **Perplexity** instead: pay only for what you use (no monthly fee; see [Perplexity pricing](https://docs.perplexity.ai/guides/pricing)).

1. Sign up at [perplexity.ai](https://www.perplexity.ai/) and get an API key from your account/settings (or use [OpenRouter](https://openrouter.ai/) and set `OPENROUTER_API_KEY` instead).
2. Add to `.env`:
   ```bash
   PERPLEXITY_API_KEY=pplx-...your-key...
   ```
3. Set the provider in config (see below) so `web_search` uses Perplexity.
4. Restart: `./scripts/compose-up.sh -d`.

**Config:** Ensure `config/openclaw.json` (or `config-runtime` after sync) includes:

```json
"tools": {
  "web": {
    "search": {
      "enabled": true,
      "provider": "perplexity"
    }
  }
}
```

If you use OpenRouter instead of Perplexity directly, set `OPENROUTER_API_KEY` in `.env` and use the same `"provider": "perplexity"`; OpenClaw will use OpenRouter’s base URL when it sees an OpenRouter key.

---

### Option B: Disable web search (no key, no cost)

If you don’t need web search, you can turn it off. The “missing API key” message will stop. The agent can still use:

- **Weather** (bundled skill, no key)
- **web_fetch** (fetch a specific URL when the user provides it)
- Other tools and skills

**Config:** Add to `config/openclaw.json` (then run `./scripts/compose-up.sh` so `config-runtime` is updated):

```json
"tools": {
  "web": {
    "search": {
      "enabled": false
    }
  }
}
```

After the next sync/restart, the gateway will not offer `web_search` to the agent, so it won’t try to use it and won’t report a missing key.

---

**Check that the container sees your env** (without printing the key):

```bash
docker exec openclaw_secure node -e "const p=process.env.PERPLEXITY_API_KEY||''; console.log('PERPLEXITY_API_KEY set:', !!p.length)"
```

If you only need **weather**: the bundled weather skill uses wttr.in and needs **no** API key. If the bot still says “missing API key” for a weather request, it may be trying web_search; use Option A (Perplexity) or Option B (disable search) above.

---

## Summary

| Goal | Action |
|------|--------|
| **See what’s available** | Built-in tools: exec, web_search, web_fetch, browser, file ops, memory, sessions, message, cron, etc. For this image, see **Bundled skills in this image** (full list + weather = no API key). |
| **Weather (this image)** | No setup. Bundled weather skill uses wttr.in + Open-Meteo (no key). |
| **Weather (OpenWeatherMap)** | Only if you use a different weather skill: add `OPENWEATHERMAP_API_KEY=...` to `.env`, restart. |
| **Add web search** | No free Brave tier. Use **Perplexity** (pay-as-you-go): set `PERPLEXITY_API_KEY` in `.env`, set `tools.web.search.provider` to `"perplexity"` in config, restart. Or **disable** search: `tools.web.search.enabled: false` (no key, no cost). |
| **Add other skills** | Install from ClawHub into a skills dir the container sees, or use an image that includes the skill; set any required env vars in `.env`. |

For more on tools and skills: [OpenClaw Tools](https://docs.openclaw.ai/tools), [Skills](https://docs.openclaw.ai/tools/skills), [ClawHub](https://clawhub.com).
