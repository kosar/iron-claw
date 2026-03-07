---
name: productwatcher
description: Intelligent product monitoring and price tracking system. Handles queries about watchlists, tracks price drops and stock availability, manages watch lifecycle (add, remove, mark purchased), and provides status updates. Use when users mention watching products, tracking prices, monitoring inventory, or ask about their watchlist status.
---

# ProductWatcher

A modular skill for intelligent product monitoring with multi-tier provider support and smart notifications. Can monitor JS-heavy and bot-protected sites (e.g. Tesla used inventory, Amazon) via browser automation when direct scrape fails.

## Quick Reference

| User Intent | Action | Response Pattern |
|-------------|--------|------------------|
| "Watch this product" / "Track this URL" | Add watch | Acknowledge, confirm target price if mentioned |
| "I bought it" / "Stop tracking" / "Not interested" | Archive watch | Disable watch, log reason, confirm |
| "What's on my watchlist?" | Status query | List active watches with last known prices |
| "Any price drops?" / "Back in stock?" | Event query | Check recent snapshots, report significant events |
| "Remove from watchlist" | Unwatch | Archive with "user_removed" reason |

## Vault Structure

```
watcher_vault/
├── watches.json       # Active watches + user preferences
├── market_data.json   # Price/inventory history
└── health_log.json    # Success/failure tracking per provider
```

## Core Operations

### 1. Adding a Watch

When user shares a product URL or asks to watch something:

1. Extract product URL from message
2. Parse merchant domain (shopify, amazon, etc.)
3. Ask target price (optional but recommended)
4. Generate watch ID: `{merchant}_{hash(url)[:8]}`
5. Append to watches.json:

```json
{
  "id": "shopify_abc123de",
  "url": "https://...",
  "merchant": "shopify",
  "target_price": 99.99,
  "track_stock": true,
  "enabled": true,
  "created_at": "2025-01-15T10:30:00Z",
  "last_checked": null,
  "last_notified": null,
  "notify_on": ["price_drop", "target_reached", "back_in_stock"],
  "user_note": "Blue sneakers size 10",
  "archived": false
}
```

6. Confirm: "✅ Watching [product name]. Target: $99.99. I'll notify you of significant changes."

### 2. Archiving a Watch (Conversational Triggers)

**Trigger phrases that disable a watch:**
- "I bought it"
- "I purchased this"
- "Stop tracking"
- "Remove from watchlist"
- "I'm not interested anymore"
- "Unwatch this"

**Process:**
1. Match the product from user's context (recently discussed or mentioned URL)
2. Set `enabled: false`, `archived: true`
3. Set `archived_reason`: "user_purchased", "user_removed", or "lost_interest"
4. Confirm: "🗑️ Stopped tracking [product]. Moved to archive."

### 3. Status Queries

**"What's on my watchlist?" / "What are we watching?"**

Load watches.json, filter `enabled: true and archived: false`, return formatted list:

```
📋 Your Watchlist (3 active)

1. Blue Sneakers — $129.99 → Target: $99.99
   Last checked: 2 hours ago

2. Wireless Headphones — $79.99 → Target: $60.00
   Last checked: 5 minutes ago

3. Desk Lamp — Out of stock → Track for restock
   Last checked: 1 hour ago
```

**"Any recent price drops?" / "Items back in stock?"**

1. Load market_data.json snapshots from last 48 hours
2. Compare to previous snapshots per watch
3. Filter for significant events:
   - Price dropped >5%
   - Price at or below target
   - Stock changed from out→in
4. Format and return events, or: "No significant changes in the last 48 hours."

### 4. Running Engine Cycle

Execute the watcher engine via cron/heartbeat:

```bash
python3 /home/ai_sandbox/.openclaw/workspace/skills/productwatcher/scripts/watcher_engine.py
```

Or check status:

```bash
python3 /home/ai_sandbox/.openclaw/workspace/skills/productwatcher/scripts/watcher_engine.py --status
```

## Provider Engine (Three-Tier)

### Tier 1: Local Muscle

**Shopify MCP**
- Discovers MCP endpoint via `/.well-known/ucp` on the store domain
- Queries `/api/ucp/mcp` using JSON-RPC 2.0 protocol
- Optional: `SHOPIFY_CLIENT_ID` + `SHOPIFY_CLIENT_SECRET` for protected stores
- Module: `providers/shopify_mcp.py`

**Brave Search + Scraping**
- Fallback for non-Shopify merchants
- Uses Brave Search API to find current listings
- Local scraping for price extraction

### Tier 2: Premium Services

**Chatsi Provider** (`providers/chatsi.py`)
- Only invoked if `CHATSI_API_KEY` environment variable exists
- Only for domains in `CHATSI_ALLOWED_DOMAINS` list
- Loaded dynamically by watcher_engine.py

### Tier 3: Execution Intelligence

The engine logs every attempt in health_log.json:

```json
{
  "timestamp": "2025-01-15T10:30:00Z",
  "watch_id": "shopify_abc123de",
  "provider": "shopify_mcp",
  "success": true,
  "error_type": null,
  "error_message": null,
  "response_time_ms": 245,
  "strategy_used": "shopify_mcp"
}
```

**Failure Handling:**
- If a provider fails 3+ consecutive times for a watch, skip it
- Error types tracked: "timeout", "parse_error", "api_error", "rate_limited"
- Use health logs to diagnose and fix provider issues

## Smart Notification Rules

Notifications are **ONLY** sent for:

1. **Target price reached** — Current price ≤ target price
2. **New all-time low** — Price lower than any previous recorded price
3. **Back in stock** — Previously out of stock, now available

**Constraints:**
- Only during waking hours (09:00–21:00 UTC by default)
- 4-hour cooldown between notifications per watch
- Respects `quiet_mode` preference

## User Preferences

Stored in watches.json under `preferences`:

```json
{
  "notification_channels": ["telegram"],
  "quiet_mode": false,
  "waking_hours": { "start": "09:00", "end": "21:00" },
  "notification_cooldown_hours": 4
}
```

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `scripts/watcher_engine.py` | Core broker, triggered by cron |
| `scripts/watcher_engine.py --status` | Show watcher health stats |
| `scripts/watcher_engine.py --dry-run` | Test cycle without notifications |

## Example Interactions

**Adding a watch:**
```
User: Watch this https://example.com/product at $50
→ Extract URL, merchant=example, target_price=50
→ Add to watches.json
→ Confirm with emoji and details
```

**Conversational disable:**
```
User: I bought it
→ Identify most recently discussed watch
→ Set archived=true, archived_reason="user_purchased"
→ Confirm removal
```

**Status query:**
```
User: What's on my watchlist?
→ Load watches.json
→ Filter enabled & not archived
→ Format pretty list with prices
```

## Implementation Notes

- All timestamps use ISO 8601 UTC format
- Prices stored as floats, None for unavailable
- Watch IDs must be unique; use `{merchant}_{hash(url)[:8]}` pattern
- Engine is idempotent; safe to run multiple times
- Health log capped at 1000 entries (FIFO)
- Market data snapshots retained for 90 days
