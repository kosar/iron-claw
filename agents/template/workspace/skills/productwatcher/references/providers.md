# Provider Integration Guide

## Creating New Providers

Add new provider modules to `providers/` directory. Each provider must expose:

```python
def is_available() -> bool:
    """Return True if provider is configured and ready"""
    pass

def execute(watch) -> MarketSnapshot | None:
    """
    Execute provider query for a watch.
    
    Args:
        watch: WatchEntry dataclass with watch properties
        
    Returns:
        MarketSnapshot on success, None if data unavailable
        
    Raises:
        Exception on error (will be logged to health_log)
    """
    pass
```

## WatchEntry Structure

```python
@dataclass
class WatchEntry:
    id: str                    # Unique identifier
    url: str                   # Product URL
    merchant: str              # Extracted merchant domain/type
    target_price: float | None # User's target price
    track_stock: bool          # Whether to track inventory
    enabled: bool              # Active status
    created_at: str            # ISO timestamp
    last_checked: str | None   # Last successful check
    last_notified: str | None  # Last notification sent
    notify_on: list[str]       # Event types to notify for
    user_note: str             # User's description/note
    archived: bool             # Whether watch is archived
    archived_reason: str | None # Why it was archived
```

## MarketSnapshot Structure

```python
@dataclass
class MarketSnapshot:
    watch_id: str              # Reference to watch
    timestamp: str             # ISO timestamp
    price: float | None        # Current price (None if unavailable)
    currency: str              # ISO currency code
    in_stock: bool | None      # Stock status (None if unknown)
    stock_level: str | None    # "low", "normal", "high", or None
    raw_data: dict             # Provider-specific raw response
```

## Example Provider Implementation

```python
# providers/my_provider.py
import os
import requests
from datetime import datetime, timezone

def is_available() -> bool:
    return bool(os.environ.get("MY_PROVIDER_API_KEY"))

def execute(watch):
    api_key = os.environ["MY_PROVIDER_API_KEY"]
    
    response = requests.get(
        "https://api.example.com/product",
        headers={"Authorization": f"Bearer {api_key}"},
        params={"url": watch.url},
        timeout=30
    )
    response.raise_for_status()
    data = response.json()
    
    # Return MarketSnapshot-like dict
    return {
        "watch_id": watch.id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "price": data.get("price"),
        "currency": data.get("currency", "USD"),
        "in_stock": data.get("in_stock"),
        "stock_level": data.get("stock_level"),
        "raw_data": data
    }
```

## Environment Variables

| Variable | Used By | Purpose |
|----------|---------|---------|
| `CHATSI_API_KEY` | chatsi.py | API authentication |
| `CHATSI_ALLOWED_DOMAINS` | chatsi.py | Comma-separated domain allow-list |
| `SHOPIFY_MCP_ENDPOINT` | shopify_mcp.py | MCP service URL |
| `BRAVE_API_KEY` | (planned) | Brave Search API |

## Provider Strategy Order

The engine executes providers in this priority:

1. Merchant-specific (e.g., shopify_mcp for Shopify URLs)
2. Brave Search (find current listings)
3. Direct scraping (fallback for known patterns)
4. **Browser automation** (Playwright + stealth; JS-heavy and bot-protected sites like Tesla, Amazon)
5. Premium providers (Chatsi, etc.) - only if available

Providers are skipped if they've failed 3+ consecutive times for a watch.

**Browser automation** requires `playwright` and `playwright-stealth` in the container (no extra env vars). It uses Playwright’s Chromium and optional XHR interception (e.g. Tesla inventory API).
