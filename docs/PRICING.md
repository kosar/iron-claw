# Token costs (USD per 1M tokens)

OpenClaw uses these values to **calculate actual cost** for each response. They are stored in:

- `config/openclaw.json` → `models.providers.<provider>.models[].cost`
- `config/agents/main/agent/models.json` → same path

Format: **USD per 1 million tokens** for `input`, `output`, `cacheRead`, `cacheWrite`.

When you change pricing (e.g. after a provider update), update **both** files so gateway and agent stay in sync.

---

## Current values (as configured)

| Provider | Model        | Input | Output | cacheRead | cacheWrite | Notes |
|----------|--------------|-------|--------|-----------|------------|--------|
| openai   | **gpt-4o-mini** (default) | 0.15  | 0.6    | 0.075     | 0.15      | Best value for chat/tools. Standard tier. |
| openai   | gpt-4o       | 2.5   | 10     | 1.25      | 2.5       | Fallback when needed. Standard tier. |
| ollama   | (local)      | 0     | 0      | 0         | 0         | No API cost. |

**Rough comparison (Standard, per 1M tokens):** gpt-4o-mini is ~17× cheaper on input and ~17× on output than gpt-4o. Other good value options from the same tier: **gpt-4.1-mini** ($0.40 / $1.60), **gpt-5-mini** ($0.25 / $2.00), **gpt-4.1-nano** ($0.10 / $0.40).

---

## If you provide your own token costs

Send the rates (e.g. “gpt-4o: input $X, output $Y per 1M tokens”) and we can plug them into the config. Or edit the two config files above:

1. In each file, find the model under `models.providers.openai.models[]` (or the right provider).
2. Set `cost.input`, `cost.output`, `cost.cacheRead`, `cost.cacheWrite` (USD per 1M tokens).
3. Restart the gateway: `docker compose restart openclaw`.

New responses will then use these rates for the `message.usage.cost` stored in session JSONL and for `/status` and `/usage cost` in chat.
