---
name: style-profile
description: >
  Deep customer memory for fashion preferences. Maintains per-customer
  profiles with sizes, aesthetic preferences, brand affinities, budget,
  and interaction history. Powers personalized recommendations.
homepage: https://chatsi.builderzero.com
metadata:
  openclaw:
    emoji: "👤"
    requires:
      bins: ["bash"]
---

# Style Profile: Customer Memory Engine

You maintain deep, persistent style profiles for every customer you interact with. These profiles power personalized recommendations across all skills — fashion-radar filters trends by aesthetic, shopify-nexus filters products by size and budget.

## ⚠️ THIS SKILL IS YOUR ONLY MEMORY FOR CUSTOMER PREFERENCES

**Do NOT use the built-in `memory_search` tool for style/preference data.** ALL customer information (sizes, colors, aesthetics, brands, budget, body notes, style icons, experiments) MUST be stored in and read from this skill's `customer-profiles.md` file. The built-in memory_search does not use the structured profile format and breaks cross-skill personalization.

**TWO mandatory flows:**
- **Before ANY recommendation:** Read `customer-profiles.md` to check for existing profile (Read Flow)
- **After ANY interaction where you learn something new:** Update `customer-profiles.md` (Write Flow)

Both flows require logging via `style-log.sh`. Skipping either flow is a bug.

**Logging**: You MUST log every profile read/write using the logging script:

```
exec: bash /home/ai_sandbox/.openclaw/workspace/skills/style-profile/scripts/style-log.sh <event> key1=value1 key2=value2 ...
```

Logs are written to `/tmp/openclaw/style-profile.log` (JSON-per-line, viewable from host at `logs/style-profile.log`).

## Profile Storage

All profiles are stored in a single persistent file:

```
/home/ai_sandbox/.openclaw/workspace/skills/style-profile/customer-profiles.md
```

### Profile Format

Each customer gets a section:

```markdown
## [customer:{identifier}]

- **Sizes:** Tops: M | Bottoms: 30 | Shoes: 10 | Dress: 8
- **Aesthetic:** minimalist, Scandinavian-inspired, clean lines
- **Colors loves:** navy, olive, cream, slate grey
- **Colors avoids:** neon, bright pink, orange
- **Brands favorites:** Everlane, COS, Allbirds, Aritzia
- **Brands dislikes:** fast fashion (Shein, Temu)
- **Budget:** mid-range ($50-200 per piece, splurges on outerwear)
- **Body notes:** prefers relaxed fits in tops, slim/straight in bottoms
- **Style icons:** Scandinavian street style, @meganellaby
- **Experiments:** wants to try: wider leg pants, earth-tone suiting
- **History:**
  - 2026-02-15: First interaction. Asked about spring trends. Mentioned love for neutrals.
  - 2026-02-16: Searched Allbirds for wool runners, size 10. Liked Tree Runner in basin green.
```

### Customer Identifier

Use whatever uniquely identifies the customer in context:
- Telegram username (e.g., `@janedoe`)
- Name if provided (e.g., `jane`)
- HTTP session ID as fallback (e.g., `session-abc123`)

If unsure, use the most natural identifier and be consistent.

## Read Flow (Before Recommendations)

Before giving any product recommendation, trend report, or outfit suggestion — always check for an existing profile.

### Step 1: Load Profile

```
read: /home/ai_sandbox/.openclaw/workspace/skills/style-profile/customer-profiles.md
```

Search for the customer's section: `## [customer:{identifier}]`

**Log it:**
```
exec: bash /home/ai_sandbox/.openclaw/workspace/skills/style-profile/scripts/style-log.sh profile_read customer={identifier} status={found|not_found} note="{what you found or 'new customer'}"
```

### Step 2: Apply to Context

If a profile exists, use it to inform the current interaction:

- **Product searches**: Filter by known sizes, budget range, preferred brands
- **Trend reports**: Lead with trends matching their aesthetic, filter out colors they avoid
- **Outfit building**: Use their full profile — sizes for fit, aesthetic for style direction, budget for price range
- **Recommendations**: Reference their style naturally ("This aligns with your love for clean lines")

If no profile exists, proceed with reasonable defaults. You'll create a profile after the interaction.

### Usage Language

**Do:** "Based on your style..." / "Since you love earth tones..." / "In your size..."
**Don't:** "According to my records..." / "Your profile indicates..." / "My data shows..."

The profile should feel like memory, not a database lookup.

## Write Flow (After Interactions)

After every interaction where you learn something new about a customer, update their profile.

### Step 1: Identify New Information

Scan the conversation for:
- **Explicit statements**: "I'm a size 8" / "I hate yellow" / "My budget is around $100"
- **Implicit signals**: They asked about Everlane (brand interest), they're searching for running shoes (lifestyle), they mentioned a wedding (occasion context)
- **Feedback**: "Too expensive" (adjust budget), "I don't like that style" (aesthetic note), "Perfect!" (confirm preference)

### Step 2: Update Profile

If the customer already has a profile, use `edit` to update the relevant fields. Add new information, don't overwrite unless correcting something.

If this is a new customer, use `edit` to append a new section to the profiles file.

**Log it:**
```
exec: bash /home/ai_sandbox/.openclaw/workspace/skills/style-profile/scripts/style-log.sh profile_write customer={identifier} fields_updated="{comma-separated field names}" note="{what was learned}"
```

### Step 3: Update History

Always append a dated entry to the customer's History section summarizing the interaction:

```
- {date}: {brief summary of interaction and what was discussed/purchased/recommended}
```

**Log it:**
```
exec: bash /home/ai_sandbox/.openclaw/workspace/skills/style-profile/scripts/style-log.sh history_append customer={identifier} note="{interaction summary}"
```

## Privacy Rules

These are non-negotiable:

1. **Sizes and budget are sacred.** Never share one customer's sizes or budget with another. Never mention specific numbers in group contexts — use them silently to filter results.

2. **Use naturally, not clinically.** Reference profile data as natural knowledge ("Since you love earth tones...") not as database queries ("Your color preference is earth tones").

3. **Respect corrections immediately.** If a customer says "Actually I'm a size 10 now" — update the profile right away. Don't reference the old size again.

4. **Don't over-reference.** Using 1-2 profile points per interaction feels natural. Listing everything you know about them feels creepy.

5. **Body notes require extra care.** Never repeat body-related notes back to the customer. Use them silently to make better fit recommendations.

## Profile Management Script

For quick profile lookups without reading the full file:

```
exec: bash /home/ai_sandbox/.openclaw/workspace/skills/style-profile/scripts/profile-manager.sh read {identifier}
exec: bash /home/ai_sandbox/.openclaw/workspace/skills/style-profile/scripts/profile-manager.sh list
exec: bash /home/ai_sandbox/.openclaw/workspace/skills/style-profile/scripts/profile-manager.sh search {keyword}
```

## Important Notes

- **Every interaction is a learning opportunity.** Even a simple product search reveals preferences (brand, category, price sensitivity). Update the profile.
- **Logging is not optional.** Every profile read and write must be logged.
- **The profiles file is your most valuable asset.** It survives restarts and session boundaries. It's what makes you a personal stylist instead of a generic shopping assistant.
- **Cross-skill integration:** fashion-radar and shopify-nexus should both check profiles before generating results. The profile is the connective tissue between all your skills.
