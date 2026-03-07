---
name: restaurant-scout
description: >
  Restaurant discovery, reservation platform detection, and deep-link routing.
  Use when the user wants to find a restaurant, make a reservation, check availability,
  or get a direct booking link for any dining venue.
homepage: https://github.com/openclaw/openclaw
metadata:
  openclaw:
    emoji: "🍽️"
    requires:
      bins: ["bash", "python3", "curl"]
---

# Restaurant Scout — EXECUTE THESE STEPS IN ORDER. DO NOT SKIP ANY.

## Before anything else — defaults for missing fields

| Missing field | Use |
|--------------|-----|
| city | NYC |
| party_size | 2 |
| date | tomorrow (or today if "tonight") |
| time | 19:30 |

---

## STEP 1 — Log the request (exec, mandatory)

```
exec: bash /home/ai_sandbox/.openclaw/workspace/skills/restaurant-scout/scripts/scout-log.sh scout_start restaurant="{name or vibe}" city="{city}" party={n} date="{YYYY-MM-DD}" mode={named|discovery}
```

---

## STEP 2 — Load knowledge base (exec, mandatory)

```
exec: cat /home/ai_sandbox/.openclaw/workspace/skills/restaurant-scout/scout-knowledge.md
```

Note your user's `[user:profile]` defaults (home city, usual party). Note any `[restaurant:Name|City]` entries matching the request.

---

## STEP 3 — Search (web_search, mandatory for discovery; skip only for named restaurants with a fresh knowledge entry)

**Maximum 2 web_search calls total. Stop searching after 2 and move to Step 4.**

**For discovery (vague / cuisine-based request):**
```
web_search: best {cuisine} restaurants {neighborhood or city} 2026
```
Pick the top 3 candidates from results. From search snippets, note any Chef name, vibe/ambience words, signature dishes mentioned — you'll use these in Step 5 and 6. **Immediately move to Step 4. Do NOT narrate findings. Do NOT send any message.**

**For named restaurants with a fresh knowledge entry (<30 days):** skip this step entirely.

**For named restaurants with no or stale knowledge entry:**
```
web_search: {restaurant name} {city} chef menu signature dishes ambience
```
From search snippets, note: chef name, vibe/atmosphere description, 2–3 signature dishes or menu highlights, any awards (Michelin stars, James Beard). You'll store these in Step 5 and use them in Step 6.

Query rules: plain text only, no `site:`, no `OR`, no `AND`, under 100 characters.

**⚠️ After web_search completes: call build-deeplink.py immediately. Do NOT generate a text response first. Do NOT say "I found X restaurants, let me get the links." That narration IS the bug the user is complaining about. Go straight to exec.**

---

## STEP 4 — Build a deep link for EVERY candidate (exec, mandatory — one call per restaurant)

**YOU MUST CALL build-deeplink.py FOR EVERY RESTAURANT. DO NOT write URLs by hand.**

Use the platform and slug from either the knowledge base entry or the search results.

**Resy:**
```
exec: python3 /home/ai_sandbox/.openclaw/workspace/skills/restaurant-scout/scripts/build-deeplink.py --platform resy --slug {slug} --city {resy-city-code} --party {n} --date {YYYY-MM-DD}
```

**OpenTable:**
```
exec: python3 /home/ai_sandbox/.openclaw/workspace/skills/restaurant-scout/scripts/build-deeplink.py --platform opentable --slug {slug} --party {n} --date {YYYY-MM-DD} --time {HH:MM}
```

**Tock:**
```
exec: python3 /home/ai_sandbox/.openclaw/workspace/skills/restaurant-scout/scripts/build-deeplink.py --platform tock --slug {slug} --party {n} --date {YYYY-MM-DD} --time {HH:MM}
```

**SevenRooms:**
```
exec: python3 /home/ai_sandbox/.openclaw/workspace/skills/restaurant-scout/scripts/build-deeplink.py --platform sevenrooms --slug {slug} --party {n} --date {YYYY-MM-DD}
```

**Direct / unknown platform:**
```
exec: python3 /home/ai_sandbox/.openclaw/workspace/skills/restaurant-scout/scripts/build-deeplink.py --platform direct --url {homepage-url} --party {n} --date {YYYY-MM-DD} --time {HH:MM}
```

**Walk-in or call-only:** No script needed. Note phone number from knowledge base.

**If slug is unknown:** fetch the restaurant's homepage to find it:
```
web_fetch: https://{restaurant-domain}
```
Scan for `resy.com/cities/.../venues/{slug}`, `opentable.com/r/{slug}`, `exploretock.com/{slug}`, `sevenrooms.com/reservations/{slug}`.

**Multiple Nobu / chain locations:** run build-deeplink.py for EVERY location. Never ask which one.

---

## STEP 5 — Update knowledge base (write/edit, mandatory)

Update `scout-knowledge.md` — use the FULL enriched format, filling in whatever you gathered from Steps 2–3:

```
[restaurant:{Name}|{City}] Platform: {platform} | Slug: {slug} | City: {resy-code} | Phone: {phone} | Chef: {chef name if found} | Vibe: {one evocative sentence capturing decor/atmosphere/energy} | Dishes: {signature dishes, comma-separated} | Awards: {Michelin stars, James Beard, or other notable recognition} | Notes: {slot release time, walk-in tips, difficulty} | LastChecked: {today}
```

If Chef/Vibe/Dishes/Awards are unknown (search didn't reveal them), omit those fields — do not fabricate.

Also update `[user:profile]` — append this restaurant to RecentSearches, update CuisinePrefs and HomeCity if inferred.

```
exec: bash /home/ai_sandbox/.openclaw/workspace/skills/restaurant-scout/scripts/scout-log.sh memory_store restaurant="{name}" platform={platform} note="stored"
```

---

## STEP 6 — Respond in magazine style (only after Steps 1–5 are complete)

Write beautiful, evocative responses — like a well-edited food magazine, not a bot output. Use the Vibe, Chef, Dishes, and Awards from the knowledge base (or gathered in Step 3). If none of those fields exist for a restaurant, write naturally without them — never leave placeholder text like `{Vibe}`.

**Named restaurant (full editorial card):**
```
🍽️ **{Name}** — {Neighborhood}, {City}

_{Vibe sentence from knowledge base — the one-line atmosphere description}_

👨‍🍳 {Chef name} {· Awards if any, e.g. "· 3 Michelin stars"}
✨ **Must order:** {Dish 1} · {Dish 2} · {Dish 3}

{party} guests · {display date} · {display time}
→ [{label from build-deeplink.py}]({url from build-deeplink.py})
📞 {phone if available}
💡 {insider booking tip from Notes field}
```

**Walk-in / call-only (same editorial richness, different CTA):**
```
🍽️ **{Name}** — {Neighborhood}, {City}

_{Vibe sentence}_

👨‍🍳 {Chef} {· Awards}
✨ **Must order:** {Dishes}

Walk-in only — arrive by {smart time suggestion}.
📞 {phone}
💡 {tip}
```

**Discovery — multiple candidates:**
```
🍽️ {N} picks for {vibe/cuisine}, {city} — {party} guests · {date}

**1. {Name}** — {Neighborhood}
_{Vibe in one sentence}_
✨ {2–3 signature dishes}
{Platform} · [Book now →]({url from build-deeplink.py})
💡 {tip}

**2. {Name}** — {Neighborhood}
_{Vibe}_
✨ {Dishes}
{Platform} · [Book now →]({url from build-deeplink.py})

**3. {Name}** — Walk-ins only
_{Vibe}_
📞 {phone} — arrive by {time}
```

**Channel-aware formatting:** On iMessage/BlueBubbles, drop Markdown (`**`, `_`) and use emoji anchors + plain text. On Telegram, use full Markdown. Match the platform.

**Allowed closing offer (optional):** "Want me to check other dates or find more options nearby?"

---

## Hard rules

1. **Zero messages before Step 6.** No "let me check", no "one moment", no "I'll look that up", no "I found X restaurants, I'll build the links now" — that last one is the most common bug. After searching, call build-deeplink.py immediately without narrating what you found.
2. **Zero questions.** City missing → NYC. Party missing → 2. Date missing → tomorrow.
3. **Zero hand-crafted URLs.** Every link comes from build-deeplink.py output. No exceptions.
4. **Zero "want me to build links?"** — you already built them in Step 4.
5. **Zero "I can book for you."** Scout routes. User books. FORBIDDEN: "I can attempt the reservation", "want me to try to snag it".
6. **Knowledge base is a tool, not an answer.** Reading the knowledge base does not authorize a response. Steps 4 and 5 must run before Step 6.
7. **Fallback chain:** If web_search fails → web_fetch homepage directly → web_fetch platform search page → knowledge base phone. Always deliver something.
