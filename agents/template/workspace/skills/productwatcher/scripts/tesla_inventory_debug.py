#!/usr/bin/env python3
"""
One-off debug: load Tesla used inventory in Playwright, log network requests
and response bodies (JSON), and dump page text. Run inside container to learn
the exact API and DOM structure.
"""
import json
import sys
from urllib.parse import urlparse

def main():
    from playwright.sync_api import sync_playwright
    from playwright_stealth import Stealth

    url = "https://www.tesla.com/inventory/used/m3"
    seen_urls = set()
    json_responses = []

    def on_response(response):
        try:
            req_url = response.url
            if "tesla.com" not in req_url:
                return
            # Capture any JSON response that might be inventory-related
            ct = (response.headers.get("content-type") or "").lower()
            if "json" not in ct:
                return
            if req_url in seen_urls:
                return
            seen_urls.add(req_url)
            try:
                body = response.json()
            except Exception:
                try:
                    body = json.loads(response.body().decode("utf-8", errors="ignore"))
                except Exception:
                    return
            if not isinstance(body, (dict, list)):
                return
            json_responses.append({
                "url": req_url,
                "path": urlparse(req_url).path,
                "keys": list(body.keys())[:20] if isinstance(body, dict) else f"list[{len(body)}]",
                "sample": _sample(body),
            })
            print(f"[RESPONSE] {req_url[:80]}...", file=sys.stderr)
        except Exception as e:
            print(f"[on_response error] {e}", file=sys.stderr)

    def _sample(obj, max_len=500):
        s = json.dumps(obj, default=str)[:max_len]
        return s + ("..." if len(s) >= max_len else "")

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        try:
            context = browser.new_context(
                user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                viewport={"width": 1920, "height": 1080},
                ignore_https_errors=True,
                locale="en-US",
                timezone_id="America/Los_Angeles",
                extra_http_headers={
                    "Accept-Language": "en-US,en;q=0.9",
                    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
                },
            )
            context.set_default_timeout(45000)
            context.set_default_navigation_timeout(45000)
            page = context.new_page()
            Stealth().apply_stealth_sync(page)
            page.on("response", on_response)

            # Human-like: open homepage first, check if we get through
            print("Loading Tesla homepage...", file=sys.stderr)
            page.goto("https://www.tesla.com/", wait_until="domcontentloaded", timeout=20000)
            page.wait_for_timeout(2000)
            home_body = page.locator("body").inner_text(timeout=5000) or ""
            if "Access Denied" in home_body:
                print("[HOME] BLOCKED (Access Denied on homepage)", file=sys.stderr)
            else:
                print("[HOME] OK - got content", file=sys.stderr)
            page.wait_for_timeout(3000)

            # Inventory URL with params that real browser often gets (zip, arrange)
            inventory_url = "https://www.tesla.com/inventory/used/m3?arrangeby=plh&zip=98052&range=0"
            print("Navigating to inventory (with zip param)...", file=sys.stderr)
            page.goto(inventory_url, wait_until="domcontentloaded", referer="https://www.tesla.com/")
            print("Waiting for network idle (30s)...", file=sys.stderr)
            try:
                page.wait_for_load_state("networkidle", timeout=30000)
            except Exception:
                pass
            # Extra settle time
            page.wait_for_timeout(3000)

            # Try to close "Search Area" modal if present (common selectors)
            for selector in [
                'button[aria-label="Close"]',
                '[data-modal-close]',
                'button:has-text("Continue")',
                'button:has-text("Apply")',
                'button:has-text("Done")',
                '.tds-modal-close',
                'button.tds-modal-close',
            ]:
                try:
                    el = page.locator(selector).first
                    if el.count() > 0:
                        el.click(timeout=2000)
                        print(f"Clicked: {selector}", file=sys.stderr)
                        page.wait_for_timeout(2000)
                        break
                except Exception:
                    pass

            # Wait a bit more for list to load after modal dismiss
            page.wait_for_timeout(4000)

            html = page.content()
            # Check for common inventory text
            if "Price" in html and ("$" in html or "price" in html.lower()):
                print("[DOM] Page contains price-related text", file=sys.stderr)
            if "Vehicle" in html or "inventory" in html.lower():
                print("[DOM] Page contains vehicle/inventory text", file=sys.stderr)

            # Dump JSON responses for inspection
            print("\n--- JSON RESPONSES ---")
            print(json.dumps(json_responses, indent=2, default=str))

            # Dump a short excerpt of body text (no huge HTML)
            body_text = page.locator("body").inner_text(timeout=5000)
            excerpt = (body_text or "")[:3000]
            print("\n--- BODY TEXT EXCERPT ---")
            print(excerpt)

        finally:
            browser.close()

if __name__ == "__main__":
    main()
