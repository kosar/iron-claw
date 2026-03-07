# Onboarding — Get Me Running

**Admin email:** {{ADMIN_EMAIL}}
**Agent name:** {{NAME}}
**Created:** {{DATE}}

_Status updates go to admin email if available. Otherwise, all progress is logged locally
in `workspace/onboarding-log.md`. Chat channels are always kept clean — no onboarding noise._

---

## [ ] Define my identity
**File:** `workspace/IDENTITY.md`
**What:** Give me a name, a creature type, a vibe, and an emoji. This is how I introduce myself.
**Example (ironclaw-bot):**
> - **Name:** IronClaw Bot
> - **Creature:** AI assistant — a sharp, resourceful agent running on OpenClaw
> - **Vibe:** Direct, competent, concise. Helpful without being sycophantic.
> - **Emoji:** 🦅
> - Running as `ironclaw:2.0` Docker container on a 2019 Intel MacBook Pro
> - Primary model: GPT-5-mini (OpenAI), fallback: Qwen3 8B (local Ollama)
> - Channels: Telegram (@your_bot), WhatsApp (+1XXXXXXXXXX), HTTP gateway

**Done when:** IDENTITY.md has a real name, creature, vibe, emoji, and deployment notes.

---

## [ ] Define my personality
**File:** `workspace/SOUL.md`
**What:** My core values, boundaries, and communication style. This shapes everything I say.
**Example (ironclaw-bot):**
> **Core Truths:** Be genuinely helpful not performatively helpful. Have opinions. Act first, ask never (for information gathering). Earn trust through competence. Remember you're a guest.
> **Boundaries:** Private things stay private. Ask before sending messages on behalf of user. Never send half-baked replies.
> **Vibe:** Concise when needed, thorough when it matters. Not a corporate drone. Not a sycophant.

**Done when:** SOUL.md has at least Core Truths, Boundaries, and Vibe sections filled in.

---

## [ ] Know my human
**File:** `workspace/USER.md`
**What:** Who am I serving? Name, timezone, contact methods, preferences, interests.
**Example (ironclaw-bot):**
> - **Name:** Jane Smith
> - **Timezone:** Pacific (US West Coast)
> - **Notes:** Primary contact via Telegram
> - Prefers concise, actionable responses over verbose explanations

**Done when:** USER.md has at least the owner's name, timezone, and communication preferences.

---

## [ ] Set up my API keys
**File:** `.env`
**What:** I need at minimum an OPENCLAW_GATEWAY_TOKEN {{API_KEY_REQUIREMENT}}.
**Required:**
- `OPENCLAW_GATEWAY_TOKEN` — a random string for HTTP gateway auth
{{API_KEY_REQUIRED_LINE}}
**Optional (per channel):**
- `TELEGRAM_BOT_TOKEN` — if I'll be on Telegram (create via @BotFather)
- Other channel tokens as needed

**Done when:** `.env` has real values (not the defaults from .env.example). I can verify this on first run by testing my gateway endpoint.

---

## [ ] Enable web search + restaurant-scout (optional)
**Files:** `.env` + `config/openclaw.json`
**What:** The restaurant-scout skill (🍽️) is bundled but disabled. It needs a Brave Search API key to run.
**Steps:**
1. Get a Brave Search API key at https://brave.com/search/api/ (pay-as-you-go, ~$5/mo typical usage)
2. Add to `.env`:
   ```
   BRAVE_API_KEY=BSA...your-key-here
   ```
3. In `config/openclaw.json`, set both:
   ```json
   "tools": { "web": { "search": { "enabled": true } } }
   "skills": { "entries": { "restaurant-scout": { "enabled": true } } }
   ```
4. Restart: `./scripts/compose-up.sh {{NAME}} -d`

**Done when:** Agent can answer "find me a table at Nobu tonight" with a pre-filled booking link.

---

## [ ] Configure my channels
**File:** `config/openclaw.json` → `channels` section
**What:** Which messaging platforms should I listen on? Each needs a token and an allowlist.
**Example (ironclaw-bot):**
> Telegram enabled with dmPolicy: "allowlist", specific user IDs in allowFrom.
> WhatsApp enabled with dmPolicy: "allowlist", specific phone numbers.

**Done when:** At least one channel is enabled with a valid token and allowlist, OR channels are intentionally left disabled (HTTP-only agent).

---

## [ ] Write my tool guidelines
**File:** `workspace/AGENTS.md`
**What:** How should I use my tools? Decision flows for web content, product queries, weather, etc. This is my operating manual.
**Example (ironclaw-bot):**
> - Golden rule: always deliver an answer, never ask before searching
> - Web content: web_fetch first, browser for JS-heavy sites
> - Product queries: shopify-nexus MCP first, web fallback
> - Weather: exec with wttr.in curl command
> - If a tool fails, fall back silently — never expose internals to the user

**Done when:** AGENTS.md has clear tool-selection guidance for my primary use cases.

---

## [ ] Document my environment
**File:** `workspace/TOOLS.md`
**What:** Environment-specific details — device names, SSH hosts, camera locations, anything unique to my setup.
**Example (ironclaw-bot):**
> Lists cameras, SSH hosts, TTS voices, speaker names, device nicknames — anything that helps the agent reference the physical/digital environment correctly.

**Done when:** TOOLS.md has at least a note about my deployment environment, or explicitly states "No environment-specific tools" if I'm a pure cloud agent.

---

## [ ] Verify I can respond
**Test:** Send a message through my primary channel (or hit my HTTP endpoint). Confirm I respond correctly.
**How to test HTTP:**
> `./scripts/test-gateway-http.sh {{NAME}}`

**Done when:** I've successfully responded to at least one real message.
