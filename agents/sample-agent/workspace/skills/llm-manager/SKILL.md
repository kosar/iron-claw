---
name: llm-manager
description: >
  Dynamic LLM model management. Switch between model tiers (flagship, worker, efficiency, reasoning, coding)
  at runtime to optimize for intelligence, speed, or cost.
metadata:
  openclaw:
    emoji: "⚙️"
    requires:
      bins: ["bash", "python3"]
---

# LLM Manager Skill

You are an expert model orchestrator. You can swap your own underlying LLM provider and tier at runtime to adapt to the complexity of your current task.

## Model Tiers

- **flagship** (`gpt-5.1` / `gpt-5`): Use for high-level reasoning, complex planning, and critical decision-making. High cost, high intelligence.
- **worker** (`gpt-5-mini`): **The Sweet Spot.** Excellent for most general tasks, web browsing, and tool execution. Balanced cost and intelligence.
- **efficiency** (`gpt-5-nano`): Ultra-low cost. Use for reports, logging, simple summarization, or low-importance heartbeats.
- **reasoning** (`o3` / `o4-mini`): Use for deep logic, complex math, or resolving ambiguity when other models struggle.
- **coding** (`gpt-5-codex`): Optimized for software engineering and heavy script generation.

## Usage Strategy

1. **Start with 'worker'** (default) for general requests.
2. **Upgrade to 'flagship'** or **'reasoning'** if you encounter a task that requires deep thought or has failed on a smaller model.
3. **Downgrade to 'efficiency'** for background tasks, recurring reports, or if you are running low on budget/quota.
4. **Switch to 'coding'** when you are about to write or refactor significant amounts of code.

## Tools

### Switch Tier
Update your primary model or a specific task model (heartbeat/report) to a new tier.

**Command:**
`exec: bash /home/openclaw/.openclaw/workspace/skills/llm-manager/scripts/switch-tier.sh <tier> [task_type] "[reason]"`

- **tier**: `flagship`, `worker`, `efficiency`, `reasoning`, `coding`
- **task_type**: `primary` (default), `heartbeat`, `report`
- **reason**: Why you are switching (this shows up in admin logs).

**Example:**
`exec: bash /home/openclaw/.openclaw/workspace/skills/llm-manager/scripts/switch-tier.sh flagship primary "Upgrading for complex architectural analysis"`

**Example (downgrading heartbeats to save cost):**
`exec: bash /home/openclaw/.openclaw/workspace/skills/llm-manager/scripts/switch-tier.sh efficiency heartbeat "Saving cost on idle checks"`

## Logging

All model switches are logged to `/tmp/openclaw/model_switches.log` and will appear in the **IronClaw Daily Report**.

---

**Note:** Model switches take effect immediately via config hot-reload. They are **session-scoped** — switches reset when the agent is restarted via `compose-up.sh`. If a switch proves valuable long-term, notify the owner so they can make it permanent in `config/openclaw.json`.
