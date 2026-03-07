# Browser Automation Provider
"""
Nuclear option: full JS rendering + stealth for bot-protected and JS-heavy sites.
Uses Playwright with playwright-stealth; optional XHR interception (e.g. Tesla inventory).
"""

import importlib.util
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

# Load direct_scrape from same directory (providers loaded by path, not as package)
_providers_dir = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("direct_scrape", _providers_dir / "direct_scrape.py")
_direct_scrape = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_direct_scrape)
MERCHANT_PATTERNS = _direct_scrape.MERCHANT_PATTERNS
_extract_json_ld_price = _direct_scrape._extract_json_ld_price
_extract_price = _direct_scrape._extract_price
_extract_stock = _direct_scrape._extract_stock

# Navigation/timeouts
NAV_TIMEOUT_MS = 30000
DEFAULT_TIMEOUT_MS = 35000
# Human-like delay after modal dismiss (ms)
TESLA_MODAL_SETTLE_MS = 3500

# Realistic Chrome UA
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)


def is_available() -> bool:
    """True if Playwright and playwright-stealth are installed and Chromium is present."""
    try:
        from playwright.sync_api import sync_playwright
        from playwright_stealth import Stealth
    except ImportError:
        return False
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            browser.close()
    except Exception:
        return False
    return True


def _domain(watch) -> str:
    try:
        return urlparse(watch.url).netloc.lower()
    except Exception:
        return ""


# Block message from Akamai / bot protection
ACCESS_DENIED_MARKERS = ("Access Denied", "access denied", "Reference #", "edgesuite.net")


def _page_is_blocked(html: str) -> bool:
    """True if the page body indicates we were blocked (e.g. Akamai)."""
    if not html:
        return True
    html_lower = html.lower()
    return any(marker.lower() in html_lower for marker in ACCESS_DENIED_MARKERS)


def _dismiss_tesla_zip_modal(page) -> None:
    """Try to dismiss Tesla 'Search Area' zip modal so inventory list can load. Safe to call every time."""
    selectors_to_try = [
        'button[aria-label="Close"]',
        '[data-modal-close]',
        'button:has-text("Continue")',
        'button:has-text("Apply")',
        'button:has-text("Done")',
        '.tds-modal-close',
        'button.tds-modal-close',
    ]
    for sel in selectors_to_try:
        try:
            loc = page.locator(sel).first
            if loc.count() > 0:
                loc.click(timeout=2000)
                page.wait_for_timeout(1500)
                return
        except Exception:
            continue


def _extract_tesla_price_from_dom(html: str) -> float | None:
    """Extract first listing price from Tesla inventory DOM (e.g. $45,000 or data attributes)."""
    # Common patterns: $XX,XXX or "price": 45000 in inline JSON
    patterns = [
        r'"price"\s*:\s*(\d+(?:\.\d+)?)',
        r'"TotalPrice"\s*:\s*(\d+(?:\.\d+)?)',
        r'\$\s*([0-9]{2,3},[0-9]{3})',
        r'data-price=["\']?([0-9,]+)',
    ]
    for pat in patterns:
        m = re.search(pat, html)
        if m:
            try:
                return float(m.group(1).replace(",", ""))
            except ValueError:
                continue
    return None


def _extract_from_tesla_intercepted(intercepted: list[dict]) -> tuple[float | None, bool | None]:
    """Parse Tesla-style inventory API responses. Returns (price, in_stock)."""
    for data in intercepted:
        if not isinstance(data, dict):
            continue
        # Tesla inventory often has results with pricing
        results = data.get("results") or data.get("listings") or data.get("inventory")
        if isinstance(results, list) and results:
            item = results[0]
            if isinstance(item, dict):
                price = None
                for key in ("price", "TotalPrice", "price_usd", "listing_price"):
                    if key in item and item[key] is not None:
                        try:
                            price = float(str(item[key]).replace(",", "").replace("$", ""))
                            break
                        except (ValueError, TypeError):
                            pass
                # Presence of listings implies "in stock" for inventory pages
                in_stock = True if results else None
                if price is not None or in_stock is not None:
                    return price, in_stock
        # Single listing object
        for key in ("price", "TotalPrice", "price_usd", "listing_price"):
            if key in data and data[key] is not None:
                try:
                    price = float(str(data[key]).replace(",", "").replace("$", ""))
                    return price, True
                except (ValueError, TypeError):
                    pass
    return None, None


def execute(watch):
    """
    Execute browser automation for a product watch: full JS render + stealth,
    optional XHR interception (Tesla), DOM extraction fallback.
    Returns MarketSnapshot dict or None; raises on hard errors.
    """
    from playwright.sync_api import sync_playwright
    from playwright_stealth import Stealth

    intercepted_responses: list[dict] = []
    domain = _domain(watch)
    is_tesla = "tesla.com" in domain

    def _capture_json(response):
        try:
            body = response.json()
        except Exception:
            try:
                body = json.loads(response.body().decode("utf-8", errors="ignore"))
            except Exception:
                return
        if not isinstance(body, (dict, list)):
            return
        if isinstance(body, list):
            body = {"results": body}
        intercepted_responses.append(body)

    def on_response(response):
        try:
            url = response.url
            if not is_tesla:
                if "api" in url or "inventory" in url or "product" in url:
                    _capture_json(response)
                return
            # Tesla: intercept any JSON that might be inventory/search
            if "tesla.com" in url and ("inventory" in url or "search" in url or "listings" in url or "api" in url or "graphql" in url):
                _capture_json(response)
        except Exception:
            pass

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            try:
                context = browser.new_context(
                    user_agent=USER_AGENT,
                    viewport={"width": 1920, "height": 1080},
                    ignore_https_errors=True,
                )
                context.set_default_timeout(DEFAULT_TIMEOUT_MS)
                context.set_default_navigation_timeout(NAV_TIMEOUT_MS)
                page = context.new_page()
                Stealth().apply_stealth_sync(page)
                page.on("response", on_response)

                if is_tesla:
                    # Human-like: open homepage first, then inventory (may help with cookies/referrer)
                    page.goto("https://www.tesla.com/", wait_until="domcontentloaded", timeout=NAV_TIMEOUT_MS)
                    page.wait_for_timeout(2500)
                    inventory_url = watch.url
                    if "zip=" not in inventory_url:
                        inventory_url = inventory_url.rstrip("/") + "?arrangeby=plh&zip=98052&range=0"
                    page.goto(inventory_url, wait_until="domcontentloaded", referer="https://www.tesla.com/")
                else:
                    page.goto(watch.url, wait_until="domcontentloaded")
                try:
                    page.wait_for_load_state("networkidle", timeout=NAV_TIMEOUT_MS)
                except Exception:
                    pass

                html = page.content()
                if _page_is_blocked(html):
                    raise RuntimeError(
                        "browser_automation: page blocked by site (Access Denied). "
                        "Try a different network or residential proxy; see OPERATIONS.md Tesla note."
                    )

                if is_tesla:
                    _dismiss_tesla_zip_modal(page)
                    page.wait_for_timeout(TESLA_MODAL_SETTLE_MS)
                    html = page.content()
                    if _page_is_blocked(html):
                        raise RuntimeError(
                            "browser_automation: page blocked by site (Access Denied). "
                            "Try a different network or residential proxy; see OPERATIONS.md Tesla note."
                        )
            finally:
                browser.close()

        # Prefer intercepted API data (Tesla / inventory-style)
        if intercepted_responses:
            price, in_stock = _extract_from_tesla_intercepted(intercepted_responses)
            # If we got API data but no price, still return success with in_stock=True for inventory pages
            if price is not None or in_stock is not None:
                return {
                    "watch_id": watch.id,
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                    "price": price,
                    "currency": "USD",
                    "in_stock": in_stock,
                    "stock_level": None,
                    "raw_data": {
                        "source": "browser_automation",
                        "strategy": "intercepted_api",
                        "merchant": watch.merchant,
                        "response_count": len(intercepted_responses),
                    },
                }
            if is_tesla and intercepted_responses:
                # Partial success: we got Tesla API responses but couldn't parse price
                return {
                    "watch_id": watch.id,
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                    "price": None,
                    "currency": "USD",
                    "in_stock": True,
                    "stock_level": None,
                    "raw_data": {
                        "source": "browser_automation",
                        "strategy": "intercepted_api",
                        "merchant": watch.merchant,
                        "response_count": len(intercepted_responses),
                        "note": "listings_data_no_price",
                    },
                }

        # DOM fallback: Tesla-specific price from DOM, then same patterns as direct_scrape
        price = None
        in_stock = None
        if is_tesla:
            price = _extract_tesla_price_from_dom(html)
            if price is not None:
                in_stock = True
        if price is None or in_stock is None:
            patterns = MERCHANT_PATTERNS.get(watch.merchant, MERCHANT_PATTERNS["default"])
            json_price, json_stock = _extract_json_ld_price(html)
            if price is None:
                price = json_price if json_price is not None else _extract_price(html, patterns["price_patterns"])
            if in_stock is None:
                in_stock = json_stock if json_stock is not None else _extract_stock(html, patterns["stock_patterns"])

        if price is not None or in_stock is not None:
            return {
                "watch_id": watch.id,
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "price": price,
                "currency": "USD",
                "in_stock": in_stock,
                "stock_level": None,
                "raw_data": {
                    "source": "browser_automation",
                    "strategy": "dom",
                    "merchant": watch.merchant,
                },
            }

        # We got a page but no extractable data (e.g. captcha or empty)
        raise RuntimeError("browser_automation: no price or stock data extracted from page or API")

    except Exception as e:
        msg = str(e)
        if msg.strip().startswith("browser_automation:"):
            raise
        raise RuntimeError(f"browser_automation: {e}") from e
