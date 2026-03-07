# Chatsi Provider
"""
Premium provider module for Chatsi API.
Only invoked if API key exists and domain is on allow-list.

API Key requirement: CHATSI_API_KEY environment variable
Domain allow-list: CHATSI_ALLOWED_DOMAINS (comma-separated)
"""

import os
from urllib.parse import urlparse


def is_available() -> bool:
    """
    Check if Chatsi provider is available.
    Requires both API key and configured allowed domains.
    """
    api_key = os.environ.get("CHATSI_API_KEY")
    allowed = os.environ.get("CHATSI_ALLOWED_DOMAINS")
    return bool(api_key) and bool(allowed)


def _is_domain_allowed(url: str) -> bool:
    """Check if URL domain is in Chatsi allow-list"""
    allowed = os.environ.get("CHATSI_ALLOWED_DOMAINS", "")
    if not allowed:
        return False
    
    allowed_domains = [d.strip().lower() for d in allowed.split(",")]
    parsed = urlparse(url)
    domain = parsed.netloc.lower()
    
    # Check exact match or subdomain match
    for allowed in allowed_domains:
        if domain == allowed or domain.endswith(f".{allowed}"):
            return True
    return False


def execute(watch):
    """
    Execute Chatsi API query for a product watch.
    
    Args:
        watch: WatchEntry object with product details
        
    Returns:
        MarketSnapshot or None if domain not allowed or API error
    """
    from datetime import datetime, timezone
    
    if not _is_domain_allowed(watch.url):
        return None
    
    api_key = os.environ.get("CHATSI_API_KEY")
    if not api_key:
        raise RuntimeError("CHATSI_API_KEY not configured")
    
    # TODO: Implement actual Chatsi API call
    # This would make HTTP request to Chatsi endpoint
    
    return None


def _call_chatsi_api(url: str, api_key: str) -> dict:
    """
    Call Chatsi product lookup API
    
    Returns product data dict or raises exception
    """
    import requests
    
    endpoint = "https://api.chatsi.io/v1/product"
    headers = {"Authorization": f"Bearer {api_key}"}
    params = {"url": url}
    
    response = requests.get(endpoint, headers=headers, params=params, timeout=30)
    response.raise_for_status()
    
    return response.json()
