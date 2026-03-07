# ProductWatcher Operation Manual

## Quick Start

```bash
# Add a product watch
python3 scripts/add_watch.py "https://store.com/products/item" --target 49.99 --note "Blue, Size M"

# Check status
python3 scripts/watcher_engine.py --status

# Run single cycle (dry-run, no notifications)
python3 scripts/watcher_engine.py --dry-run

# Run single cycle (live, sends notifications)
python3 scripts/watcher_engine.py

# Test Telegram notifications
python3 scripts/watcher_engine.py --test-telegram
```

## Setting Up Automated Monitoring

### Option 1: System Cron (Recommended)

```bash
# Run the setup script
bash scripts/setup-cron.sh

# Or manually edit crontab:
crontab -e

# Add this line (runs every hour):
0 * * * * cd /home/ai_sandbox/.openclaw/workspace/skills/productwatcher && /usr/bin/python3 scripts/watcher_engine.py >> watcher_vault/logs/cron-$(date +\%Y\%m\%d).log 2>&1
```

### Option 2: OpenClaw Gateway Cron (If Gateway Available)

Add via `openclaw gateway` or cron API:

```json
{
  "name": "productwatcher-hourly",
  "schedule": {"kind": "every", "everyMs": 3600000},
  "payload": {
    "kind": "systemEvent",
    "text": "python3 /home/ai_sandbox/.openclaw/workspace/skills/productwatcher/scripts/watcher_engine.py"
  },
  "sessionTarget": "main",
  "enabled": true
}
```

## Architecture

### Provider Engine (Tiers 1–5)

```
Tier 1: Merchant-specific   shopify_mcp.py
Tier 2: General search      brave_search.py
Tier 3: Direct scraping    direct_scrape.py (HTTP, no JS)
Tier 4: Browser automation  browser_automation.py (Playwright + stealth, JS-heavy / bot-protected)
Tier 5: Premium             chatsi.py, etc.
```

**browser_automation** runs after direct_scrape when the page is JS-heavy or bot-protected (e.g. Tesla used inventory, Amazon). It requires Playwright and playwright-stealth in the container; uses optional XHR interception (e.g. Tesla inventory API) and DOM fallback. Health log entries use `source: "browser_automation"` and `strategy: "intercepted_api"` or `"dom"`.

### Failure Handling

- **3 consecutive failures** = provider skipped for that watch
- **All strategies fail** = user notified (for new watches)
- **Timeouts**: MCP (10s), Brave (15s), Scrape (20s)
- **Errors logged** with type categorization for diagnostics

### Notification Rules

Notifications sent **ONLY** for:
1. Target price reached (current ≤ target)
2. New all-time low (price < historical minimum)
3. Back in stock (was out, now in)

**Constraints:**
- Waking hours only: 09:00–21:00 UTC
- 4-hour cooldown between notifications per watch
- Respects `quiet_mode` preference

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `BRAVE_API_KEY` | Yes (for Brave Search) | Brave Search API key |
| `CHATSI_API_KEY` | No | Chatsi API key (premium) |
| `CHATSI_ALLOWED_DOMAINS` | No | Comma-separated domains for Chatsi |
| `SHOPIFY_CLIENT_ID` | No | For authenticated MCP stores |
| `SHOPIFY_CLIENT_SECRET` | No | For authenticated MCP stores |
| `TELEGRAM_BOT_TOKEN` | Yes (for notifications) | Telegram bot token |
| `TELEGRAM_CHAT_ID` | No | Set to your Telegram user ID (from allowFrom) or leave unset to use config |

## Vault Structure

```
watcher_vault/
├── watches.json        # Watch definitions + user preferences
├── market_data.json    # Price/inventory history (90 days)
├── health_log.json     # Provider execution diagnostics (1000 entries)
└── logs/               # Cron execution logs
    └── cron-YYYYMMDD.log
```

## Health Log Format

```json
{
  "timestamp": "2025-01-15T10:30:00Z",
  "watch_id": "shopify_abc123de",
  "provider": "shopify_mcp",
  "success": false,
  "error_type": "MCP_TIMEOUT",
  "error_message": "Request timed out after 10s",
  "response_time_ms": 10245,
  "strategy_used": "shopify_mcp"
}
```

Error types indicate what went wrong:
- `MCP_NOT_AVAILABLE`: Store doesn't expose /.well-known/ucp
- `MCP_DISCOVERY_TIMEOUT`: Store took too long to respond
- `MCP_AUTH_REQUIRED`: Store requires client credentials
- `MCP_HTTP_404`: MCP endpoint not found on store
- `HTTP_ERROR: 403`: Bot protection blocking scraper
- `HTTP_ERROR: 429`: Rate limited
- `NO_DATA`: Provider ran but found no extractable data

### Tesla and “Access Denied” (blocked by site)

Tesla’s site (and some other bot-protected pages) is served behind **Akamai**. From some networks or environments, the server returns **403 Access Denied** before any HTML/JS runs. When that happens, browser_automation will raise a clear error: *“page blocked by site (Access Denied)”* and the health log will show the failure.

**Why it happens:** The request is blocked at the edge (IP/fingerprint), not because of missing cookies or wrong URL. Common causes:

- **Datacenter or cloud IP** (e.g. many VPS, Docker host, or cloud CI)
- **Shared/VPN IP** that has been flagged
- **Headless browser fingerprint** in stricter setups

**What works when the page does load:** The provider is built to:

1. Open Tesla homepage, then inventory URL (with zip param), with normal delays.
2. Dismiss the “Search Area” zip modal (Continue/Apply/Close) so the list can load.
3. Use intercepted JSON API responses and DOM (price/listing) to build the snapshot.

So in environments where Tesla does **not** block (e.g. many home/office IPs, or when using a residential proxy), the same code path should succeed.

**Options if you see Access Denied:**

| Option | What to do |
|--------|------------|
| **Different network** | Run the watcher (or a one-off browser run) from a machine on a residential or non-flagged IP (e.g. home, different ISP). |
| **Residential proxy** | Use an HTTP(S) proxy that provides residential IPs and configure the browser context to use it (proxy server + optional auth). Requires code/config change to pass proxy into the Playwright context. |
| **Host network** | If the host machine can load Tesla in a normal browser, try running the container with `--network host` so egress uses the host IP. This does not always fix the block (block can be fingerprint-based). |
| **Accept no Tesla** | If Tesla is optional, leave the watch in place; other providers will keep trying, and browser_automation will log the block. |

There is no in-repo secret or config that “unlocks” Tesla; the block is on the server side based on network and/or client fingerprint.

## Troubleshooting

### No providers available
```bash
python3 scripts/watcher_engine.py --status
# Check that BRAVE_API_KEY is set
env | grep BRAVE
```

### Shopify MCP not available
The MCP provider checks for `/.well-known/ucp` on the store domain:
- If 404: Store doesn't expose MCP (falls back to scraping)
- If found: Queries `/api/ucp/mcp` for product data

**Authentication (optional):**
Some stores require OAuth. Set credentials:
```bash
export SHOPIFY_CLIENT_ID="your_client_id"
export SHOPIFY_CLIENT_SECRET="your_client_secret"
```

### Telegram not working
```bash
# Test Telegram
python3 scripts/watcher_engine.py --test-telegram

# Check token
env | grep TELEGRAM
```

### High failure rate on a watch
Check health log for patterns:
```bash
cat watcher_vault/health_log.json | jq '.entries[-20:]'
```

If a provider fails 3+ times, it's automatically skipped. Delete health entries to retry.

## Adding New Providers

1. Create `providers/my_provider.py`:
```python
def is_available() -> bool:
    return bool(os.environ.get("MY_API_KEY"))

def execute(watch):
    # Return MarketSnapshot dict or None
    return {
        "watch_id": watch.id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "price": 49.99,
        "currency": "USD",
        "in_stock": True,
        "stock_level": "normal",
        "raw_data": {"source": "my_provider"}
    }
```

2. The engine auto-loads it on next run.

## Conversational Commands

When chatting with the AI:

| You say | AI does |
|---------|---------|
| "Watch this [URL]" | Adds to watchlist |
| "Watch this at $50" | Adds with target price |
| "I bought it" | Archives the watch |
| "Stop tracking [URL]" | Disables watch |
| "What's on my watchlist?" | Lists active watches |
| "Any price drops?" | Reports recent changes |
