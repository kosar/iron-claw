#!/usr/bin/env python3
"""
Test browser_automation provider against known tricky sites.
Run inside the pibot container after image build:
  docker exec <pibot_secure> python3 /home/openclaw/.openclaw/workspace/skills/productwatcher/scripts/test_browser_provider.py [url ...]
Exit 0 if at least one URL returns a snapshot with data; non-zero otherwise.
"""

import importlib.util
import sys
from datetime import datetime, timezone
from pathlib import Path

# Default test URLs: Tesla, Amazon, Zillow, Best Buy
DEFAULT_URLS = [
    "https://www.tesla.com/inventory/used/m3",
    "https://www.amazon.com/dp/B09V3KXJPB",
    "https://www.zillow.com/homes/for_sale/",
    "https://www.bestbuy.com/site/searchpage.jsp?st=macbook",
]

SKILL_DIR = Path(__file__).resolve().parent.parent
PROVIDERS_DIR = SKILL_DIR / "providers"


def _make_watch(url: str, watch_id: str = "test", merchant: str = "default"):
    """Minimal watch-like object for the provider."""
    from types import SimpleNamespace
    return SimpleNamespace(
        id=watch_id,
        url=url,
        merchant=merchant,
        target_price=None,
        track_stock=True,
        enabled=True,
        created_at=datetime.now(timezone.utc).isoformat(),
        last_checked=None,
        last_notified=None,
        notify_on=[],
        user_note="",
        archived=False,
        archived_reason=None,
    )


def _load_provider():
    """Load browser_automation module from providers/."""
    path = PROVIDERS_DIR / "browser_automation.py"
    spec = importlib.util.spec_from_file_location("browser_automation", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    urls = sys.argv[1:] if len(sys.argv) > 1 else DEFAULT_URLS
    provider = _load_provider()

    if not provider.is_available():
        print("[FAIL] browser_automation is not available (missing playwright/stealth or chromium)")
        return 2

    print("[INFO] browser_automation is available")
    success_count = 0
    for i, url in enumerate(urls):
        watch = _make_watch(url, watch_id=f"test_{i}", merchant="default")
        print(f"\n--- {url[:60]}...")
        try:
            result = provider.execute(watch)
            if result and (result.get("price") is not None or result.get("in_stock") is not None):
                print(f"  OK   price={result.get('price')} in_stock={result.get('in_stock')} raw={result.get('raw_data', {}).get('source')}")
                success_count += 1
            else:
                print(f"  SKIP no price/stock in snapshot: {result}")
        except Exception as e:
            print(f"  FAIL {e}")
    print()
    if success_count > 0:
        print(f"[PASS] {success_count}/{len(urls)} URLs returned data")
        return 0
    print("[FAIL] no URL returned price or stock data")
    return 1


if __name__ == "__main__":
    sys.exit(main())
