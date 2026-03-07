# Direct Scrape Provider
"""
Local Muscle: Direct HTTP scraping for product pages
Uses stdlib urllib with timeouts and SSL context
"""

import json
import re
import ssl
import urllib.request
from datetime import datetime, timezone
from urllib.parse import urlparse

# Merchant-specific extraction patterns
MERCHANT_PATTERNS = {
    "shopify": {
        "price_patterns": [
            r'"price":\s*([0-9.]+)',
            r'"price"\s*:\s*"\$?([0-9.,]+)"',
            r'class=["\']price["\'][^>]*>\$?([0-9.,]+)',
            r'data-price=["\']?([0-9.,]+)',
        ],
        "stock_patterns": {
            "in_stock": [
                r'"available":\s*true',
                r'"in_stock":\s*true',
                r'"inventory_quantity":\s*[1-9]',
                r'add to cart',
                r'in stock',
            ],
            "out_of_stock": [
                r'"available":\s*false',
                r'"in_stock":\s*false',
                r'"inventory_quantity":\s*0',
                r'sold out',
                r'out of stock',
                r'unavailable',
            ]
        },
        "json_ld": True,  # Look for JSON-LD structured data
    },
    "default": {
        "price_patterns": [
            r'["\']price["\']\s*[:=]\s*["\']?\$?([0-9,]+\.\d{2})',
            r'class=["\'][^"\']*price[^"\']*["\'][^>]*>\$?([0-9.,]+)',
            r'\$([0-9,]+\.\d{2})',
        ],
        "stock_patterns": {
            "in_stock": [r'in stock', r'available', r'add to cart'],
            "out_of_stock": [r'out of stock', r'sold out', r'unavailable'],
        },
        "json_ld": True,
    }
}


def is_available() -> bool:
    """Direct scraping is always available (uses stdlib only)"""
    return True


def _fetch_page(url: str, timeout: int = 20) -> str:
    """Fetch page content with timeout and proper headers"""
    
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
        "Accept-Encoding": "identity",
        "DNT": "1",
        "Connection": "keep-alive",
    }
    
    req = urllib.request.Request(url, headers=headers)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # Some Shopify stores have cert issues
    
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
        return resp.read().decode("utf-8", errors="ignore")


def _extract_json_ld_price(html: str) -> tuple[float | None, bool | None]:
    """Extract price and availability from JSON-LD structured data"""
    import json
    
    # Find JSON-LD scripts
    pattern = r'<script type=["\']application/ld\+json["\'][^>]*>(.*?)</script>'
    matches = re.findall(pattern, html, re.DOTALL | re.IGNORECASE)
    
    for match in matches:
        try:
            data = json.loads(match.strip())
            
            # Handle both single object and array
            items = data if isinstance(data, list) else [data]
            
            for item in items:
                if item.get("@type") in ["Product", "Offer"]:
                    # Get price
                    price = None
                    if "offers" in item:
                        offers = item["offers"]
                        if isinstance(offers, list):
                            offers = offers[0]
                        price_str = offers.get("price") or offers.get("lowPrice")
                        if price_str:
                            try:
                                price = float(str(price_str).replace(",", ""))
                            except ValueError:
                                pass
                        
                        # Get availability
                        availability = offers.get("availability", "")
                        in_stock = None
                        if "InStock" in availability:
                            in_stock = True
                        elif "OutOfStock" in availability or "SoldOut" in availability:
                            in_stock = False
                        
                        if price is not None or in_stock is not None:
                            return price, in_stock
                    
                    # Direct price field
                    if "price" in item:
                        try:
                            price = float(str(item["price"]).replace(",", ""))
                        except ValueError:
                            pass
        
        except (json.JSONDecodeError, ValueError):
            continue
    
    return None, None


def _extract_price(html: str, patterns: list[str]) -> float | None:
    """Extract price using regex patterns"""
    for pattern in patterns:
        matches = re.findall(pattern, html, re.IGNORECASE)
        if matches:
            price_str = matches[0]
            if isinstance(price_str, tuple):
                price_str = price_str[0]
            price_str = price_str.replace(",", "").replace("$", "")
            try:
                return float(price_str)
            except ValueError:
                continue
    return None


def _extract_stock(html: str, patterns: dict) -> bool | None:
    """Extract stock status using regex patterns"""
    html_lower = html.lower()
    
    # Check out of stock first (more definitive)
    for pattern in patterns.get("out_of_stock", []):
        if re.search(pattern, html_lower, re.IGNORECASE):
            return False
    
    # Check in stock
    for pattern in patterns.get("in_stock", []):
        if re.search(pattern, html_lower, re.IGNORECASE):
            return True
    
    return None


def execute(watch):
    """
    Execute direct scrape strategy for a product watch.
    
    Fetches the product page and extracts price/stock information
    using merchant-specific patterns and JSON-LD structured data.
    
    Returns:
        MarketSnapshot or None if data cannot be extracted
    """
    try:
        # Fetch page with timeout
        html = _fetch_page(watch.url, timeout=20)
        
        # Get patterns for merchant (or use default)
        patterns = MERCHANT_PATTERNS.get(watch.merchant, MERCHANT_PATTERNS["default"])
        
        # Try JSON-LD first (most reliable)
        json_price, json_stock = _extract_json_ld_price(html)
        
        # Fallback to regex patterns
        price = json_price if json_price is not None else _extract_price(html, patterns["price_patterns"])
        in_stock = json_stock if json_stock is not None else _extract_stock(html, patterns["stock_patterns"])
        
        # Build snapshot
        return {
            "watch_id": watch.id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "price": price,
            "currency": "USD",  # Default assumption
            "in_stock": in_stock,
            "stock_level": None,
            "raw_data": {
                "source": "direct_scrape",
                "merchant": watch.merchant,
                "json_ld_used": json_price is not None or json_stock is not None,
                "page_fetched": True
            }
        }
        
    except urllib.error.HTTPError as e:
        if e.code == 403:
            raise RuntimeError(f"Access denied (403) - bot protection")
        elif e.code == 429:
            raise RuntimeError(f"Rate limited (429)")
        else:
            raise RuntimeError(f"HTTP error: {e.code}")
    except urllib.error.URLError as e:
        raise RuntimeError(f"Network error: {e.reason}")
    except TimeoutError:
        raise RuntimeError(f"Timeout fetching page")
    except Exception as e:
        raise RuntimeError(f"Scrape error: {e}")
