# Brave Search Provider
"""
Local Muscle: Brave Search API + basic scraping for product discovery
Uses BRAVE_API_KEY environment variable
"""

import json
import os
import ssl
import urllib.request
from urllib.parse import quote, urlparse
from datetime import datetime, timezone

BRAVE_API_ENDPOINT = "https://api.search.brave.com/res/v1/web/search"


def is_available() -> bool:
    """Check if Brave Search API is configured"""
    return bool(os.environ.get("BRAVE_API_KEY"))


def _brave_search(query: str, count: int = 5) -> dict:
    """Execute Brave Search API call"""
    api_key = os.environ.get("BRAVE_API_KEY")
    if not api_key:
        raise RuntimeError("BRAVE_API_KEY not configured")
    
    url = f"{BRAVE_API_ENDPOINT}?q={quote(query)}&count={count}"
    
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "X-Subscription-Token": api_key
        }
    )
    
    # 15 second timeout
    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=15, context=ctx) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _extract_price_from_snippet(snippet: str) -> tuple[float | None, str]:
    """Extract price from search snippet text"""
    import re
    
    # Common price patterns: $49.99, 49.99 USD, $1,299.00
    patterns = [
        r'\$([0-9,]+\.\d{2})',  # $49.99 or $1,299.00
        r'([0-9,]+\.\d{2})\s*(USD|\$)',  # 49.99 USD
        r'price[:\s]*\$?([0-9,]+\.?\d*)',  # price: $49.99 or price 49.99
    ]
    
    for pattern in patterns:
        matches = re.findall(pattern, snippet, re.IGNORECASE)
        if matches:
            # Clean and parse price
            price_str = matches[0] if isinstance(matches[0], str) else matches[0][0]
            price_str = price_str.replace(",", "")
            try:
                return float(price_str), "USD"
            except ValueError:
                continue
    
    return None, "USD"


def _extract_stock_status(snippet: str) -> bool | None:
    """Extract stock status from search snippet"""
    snippet_lower = snippet.lower()
    
    in_stock_indicators = [
        "in stock", "available", "add to cart", "buy now", 
        "ships today", "ready to ship", "free shipping"
    ]
    out_stock_indicators = [
        "out of stock", "sold out", "unavailable", "backorder",
        "notify me", "coming soon", "temporarily unavailable"
    ]
    
    for indicator in out_stock_indicators:
        if indicator in snippet_lower:
            return False
    
    for indicator in in_stock_indicators:
        if indicator in snippet_lower:
            return True
    
    return None


def execute(watch):
    """
    Execute Brave Search strategy for a product watch.
    
    Searches for the product URL to find current listings and extracts
    price/stock information from search results.
    
    Returns:
        MarketSnapshot or None if no data found
    """
    if not is_available():
        return None
    
    try:
        # Parse product info from URL for search query
        parsed = urlparse(watch.url)
        domain = parsed.netloc.replace("www.", "")
        
        # Try to extract product name from URL path
        path_parts = parsed.path.strip("/").split("/")
        product_slug = None
        
        if "products" in path_parts:
            idx = path_parts.index("products")
            if idx + 1 < len(path_parts):
                product_slug = path_parts[idx + 1].replace("-", " ").replace("_", " ")
        elif path_parts:
            # Use last part of path as product name
            product_slug = path_parts[-1].replace("-", " ").replace("_", " ")
        
        if not product_slug:
            return None
        
        # Build search query - search for product on the same domain
        query = f"{product_slug} site:{domain}"
        
        # Call Brave Search API
        search_result = _brave_search(query, count=3)
        
        # Extract web results
        web_results = search_result.get("web", {}).get("results", [])
        
        if not web_results:
            return None
        
        # Use the first result that matches our domain
        best_result = None
        for result in web_results:
            result_url = result.get("url", "")
            if domain in result_url:
                best_result = result
                break
        
        if not best_result:
            best_result = web_results[0]  # Fall back to first result
        
        # Extract information from result
        snippet = best_result.get("description", "")
        title = best_result.get("title", "")
        combined_text = f"{title} {snippet}"
        
        price, currency = _extract_price_from_snippet(combined_text)
        in_stock = _extract_stock_status(combined_text)
        
        # Build snapshot
        return {
            "watch_id": watch.id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "price": price,
            "currency": currency,
            "in_stock": in_stock,
            "stock_level": None,
            "raw_data": {
                "source": "brave_search",
                "title": title,
                "snippet": snippet,
                "search_url": best_result.get("url"),
                "query": query
            }
        }
        
    except urllib.error.HTTPError as e:
        # Log rate limiting or auth issues
        raise RuntimeError(f"Brave API error: {e.code} - {e.reason}")
    except urllib.error.URLError as e:
        raise RuntimeError(f"Network error: {e.reason}")
    except Exception as e:
        raise RuntimeError(f"Unexpected error: {e}")
