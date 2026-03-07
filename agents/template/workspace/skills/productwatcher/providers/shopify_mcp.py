# Shopify MCP Provider
"""
Shopify MCP Provider - Discovers and queries Shopify store MCP endpoints

Discovery flow:
1. Check if store has /.well-known/ucp endpoint
2. If yes, query /api/ucp/mcp for product data
3. Use JSON-RPC 2.0 protocol

Note: Some stores may require authentication (client credentials flow)
"""

import json
import os
import ssl
import urllib.request
from datetime import datetime, timezone
from urllib.parse import urlparse, urlencode

# MCP Configuration
MCP_DISCOVERY_TIMEOUT = 8  # seconds for discovery check
MCP_REQUEST_TIMEOUT = 15   # seconds for product query


def _fetch_json(url: str, timeout: int, headers: dict | None = None, data: bytes | None = None) -> dict:
    """Fetch JSON from URL with proper error handling"""
    req = urllib.request.Request(
        url,
        headers=headers or {},
        data=data,
        method="POST" if data else "GET"
    )
    
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _parse_shopify_url(url: str) -> tuple[str, str, str] | None:
    """
    Parse Shopify URL to extract store domain and product handle.
    
    Returns:
        (full_domain, store_domain, product_handle) or None
    """
    parsed = urlparse(url)
    
    full_domain = parsed.netloc.lower()
    if not full_domain:
        return None
    
    # Extract product handle from URL path
    # Patterns:
    # /products/product-handle
    # /collections/all/products/product-handle
    path_parts = parsed.path.strip("/").split("/")
    
    if "products" not in path_parts:
        return None
    
    idx = path_parts.index("products")
    if idx + 1 >= len(path_parts):
        return None
    
    product_handle = path_parts[idx + 1]
    
    # Clean up domain (remove www, get base store name)
    store_domain = full_domain.replace("www.", "").replace(".myshopify.com", "")
    
    return full_domain, store_domain, product_handle


def _check_mcp_discovery(domain: str) -> bool:
    """
    Check if store has MCP endpoint via /.well-known/ucp discovery.
    
    Returns True if MCP is available on this store.
    """
    discovery_url = f"https://{domain}/.well-known/ucp"
    
    try:
        result = _fetch_json(discovery_url, timeout=MCP_DISCOVERY_TIMEOUT)
        # If we get a valid JSON response with UCP data, MCP is available
        return isinstance(result, dict) and ("ucp" in result or "capabilities" in result)
    except urllib.error.HTTPError as e:
        # 404 means no MCP endpoint
        if e.code == 404:
            return False
        # Other errors might be transient
        raise RuntimeError(f"MCP_DISCOVERY_HTTP_{e.code}: {e.reason}")
    except urllib.error.URLError as e:
        raise RuntimeError(f"MCP_DISCOVERY_NETWORK: {e.reason}")
    except TimeoutError:
        raise RuntimeError(f"MCP_DISCOVERY_TIMEOUT")
    except json.JSONDecodeError:
        # Not valid JSON, likely not an MCP endpoint
        return False


def _get_access_token() -> str | None:
    """
    Get Shopify access token if credentials are configured.
    
    Uses SHOPIFY_CLIENT_ID and SHOPIFY_CLIENT_SECRET env vars.
    """
    client_id = os.environ.get("SHOPIFY_CLIENT_ID")
    client_secret = os.environ.get("SHOPIFY_CLIENT_SECRET")
    
    if not client_id or not client_secret:
        return None
    
    try:
        auth_url = "https://api.shopify.com/auth/access_token"
        payload = json.dumps({
            "client_id": client_id,
            "client_secret": client_secret,
            "grant_type": "client_credentials"
        }).encode("utf-8")
        
        headers = {
            "Content-Type": "application/json"
        }
        
        result = _fetch_json(auth_url, timeout=10, headers=headers, data=payload)
        return result.get("access_token")
        
    except Exception:
        return None


def _query_product_mcp(domain: str, handle: str, token: str | None = None) -> dict:
    """
    Query product data via Shopify MCP endpoint.
    
    Uses tools/list or specific product lookup via JSON-RPC 2.0.
    """
    mcp_url = f"https://{domain}/api/ucp/mcp"
    
    # Build JSON-RPC 2.0 request
    # We'll try to use search_product or get_product_by_handle
    payload = {
        "jsonrpc": "2.0",
        "method": "tools/call",
        "id": 1,
        "params": {
            "name": "search_products",  # or "get_product"
            "arguments": {
                "meta": {
                    "ucp-agent": {
                        "profile": "https://productwatcher.local/.well-known/ucp"
                    }
                },
                "query": handle,
                "limit": 1
            }
        }
    }
    
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json"
    }
    
    if token:
        headers["Authorization"] = f"Bearer {token}"
    
    try:
        result = _fetch_json(
            mcp_url,
            timeout=MCP_REQUEST_TIMEOUT,
            headers=headers,
            data=json.dumps(payload).encode("utf-8")
        )
        return result
        
    except urllib.error.HTTPError as e:
        if e.code == 401:
            raise RuntimeError("MCP_AUTH_REQUIRED: Store requires authentication")
        elif e.code == 404:
            raise RuntimeError("MCP_ENDPOINT_NOT_FOUND: Store may not support MCP")
        else:
            raise RuntimeError(f"MCP_HTTP_{e.code}: {e.reason}")
    except Exception as e:
        raise RuntimeError(f"MCP_QUERY_ERROR: {e}")


def _extract_product_from_mcp_response(response: dict) -> tuple[float | None, bool | None, dict]:
    """
    Extract price and stock from MCP response.
    
    Returns: (price, in_stock, metadata)
    """
    result = response.get("result", {})
    structured = result.get("structuredContent", {})
    
    # Handle different response structures
    offers = structured.get("offers", [])
    if not offers:
        # Try alternative paths
        products = structured.get("products", [])
        if products:
            product = products[0]
            price_data = product.get("price", {})
            price_str = price_data.get("amount")
            price = float(price_str) if price_str else None
            in_stock = product.get("availableForSale")
            return price, in_stock, product
        return None, None, {}
    
    # Use first offer
    offer = offers[0]
    price_range = offer.get("priceRange", {})
    min_price = price_range.get("min", {})
    price_str = min_price.get("amount")
    
    try:
        price = float(price_str) if price_str else None
    except (ValueError, TypeError):
        price = None
    
    in_stock = offer.get("availableForSale")
    
    return price, in_stock, offer


def is_available() -> bool:
    """
    MCP availability is determined per-store during execution.
    Always returns True to allow attempt.
    """
    return True


def execute(watch):
    """
    Execute Shopify MCP strategy for a product watch.
    
    1. Parse URL to get domain and handle
    2. Check /.well-known/ucp for MCP availability
    3. Query /api/ucp/mcp for product data
    4. Extract price and availability
    
    Returns:
        MarketSnapshot dict or None
        
    Raises:
        RuntimeError with descriptive error type for health logging
    """
    # Parse URL
    parsed = _parse_shopify_url(watch.url)
    if not parsed:
        raise RuntimeError("URL_PARSE_ERROR: Not a valid Shopify product URL")
    
    full_domain, store_domain, handle = parsed
    
    try:
        # Step 1: Check MCP discovery
        has_mcp = _check_mcp_discovery(full_domain)
        
        if not has_mcp:
            raise RuntimeError("MCP_NOT_AVAILABLE: Store does not expose MCP endpoint")
        
        # Step 2: Try to get access token (optional, for protected stores)
        token = _get_access_token()
        
        # Step 3: Query MCP endpoint
        response = _query_product_mcp(full_domain, handle, token)
        
        # Step 4: Extract product data
        price, in_stock, metadata = _extract_product_from_mcp_response(response)
        
        if price is None and in_stock is None:
            raise RuntimeError("MCP_NO_PRODUCT_DATA: MCP responded but no product data found")
        
        # Determine stock level
        stock_level = None
        if in_stock is not None:
            # Try to get inventory count from metadata
            inventory = metadata.get("inventory_quantity")
            if inventory is not None:
                if inventory <= 5:
                    stock_level = "low"
                elif inventory <= 20:
                    stock_level = "normal"
                else:
                    stock_level = "high"
        
        return {
            "watch_id": watch.id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "price": price,
            "currency": metadata.get("price", {}).get("currencyCode", "USD") if isinstance(metadata.get("price"), dict) else "USD",
            "in_stock": in_stock,
            "stock_level": stock_level,
            "raw_data": {
                "source": "shopify_mcp",
                "store_domain": store_domain,
                "full_domain": full_domain,
                "handle": handle,
                "mcp_available": True,
                "authenticated": token is not None,
                "metadata": metadata
            }
        }
        
    except RuntimeError:
        # Re-raise with proper error categorization
        raise
    except Exception as e:
        raise RuntimeError(f"MCP_UNEXPECTED_ERROR: {type(e).__name__}: {e}")
