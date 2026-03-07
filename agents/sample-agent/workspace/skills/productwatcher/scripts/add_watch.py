#!/usr/bin/env python3
"""
Quick-add script for ProductWatcher watches
Usage: python3 add_watch.py <url> [--target <price>] [--note <note>]
"""

import json
import hashlib
import argparse
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

VAULT_DIR = Path(__file__).parent.parent / "watcher_vault"
WATCHES_FILE = VAULT_DIR / "watches.json"


def extract_merchant(url: str) -> str:
    """Extract merchant type from URL"""
    parsed = urlparse(url)
    domain = parsed.netloc.lower()
    
    if "shopify" in domain or "/products/" in parsed.path:
        return "shopify"
    elif "amazon" in domain:
        return "amazon"
    elif "ebay" in domain:
        return "ebay"
    else:
        # Use domain as merchant
        return domain.replace("www.", "").split(".")[0]


def generate_watch_id(url: str, merchant: str) -> str:
    """Generate unique watch ID"""
    url_hash = hashlib.md5(url.encode()).hexdigest()[:8]
    return f"{merchant}_{url_hash}"


def add_watch(url: str, target_price: float | None, note: str):
    """Add a new watch to the vault"""
    
    # Load existing watches
    with open(WATCHES_FILE, "r") as f:
        data = json.load(f)
    
    merchant = extract_merchant(url)
    watch_id = generate_watch_id(url, merchant)
    
    # Check for duplicates
    for w in data["watches"]:
        if w["id"] == watch_id:
            print(f"⚠️  Watch already exists: {watch_id}")
            return
    
    # Create new watch
    watch = {
        "id": watch_id,
        "url": url,
        "merchant": merchant,
        "target_price": target_price,
        "track_stock": True,
        "enabled": True,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "last_checked": None,
        "last_notified": None,
        "notify_on": ["price_drop", "target_reached", "back_in_stock"],
        "user_note": note or "",
        "archived": False,
        "archived_reason": None
    }
    
    data["watches"].append(watch)
    
    # Save
    with open(WATCHES_FILE, "w") as f:
        json.dump(data, f, indent=2)
    
    print(f"✅ Added watch: {watch_id}")
    print(f"   URL: {url}")
    print(f"   Target: ${target_price:.2f}" if target_price else "   Tracking price changes")
    print(f"   Note: {note}" if note else "")


def list_watches():
    """List all active watches"""
    with open(WATCHES_FILE, "r") as f:
        data = json.load(f)
    
    active = [w for w in data["watches"] if w["enabled"] and not w["archived"]]
    archived = [w for w in data["watches"] if w["archived"]]
    
    print(f"\n📋 Active Watches ({len(active)})")
    print("-" * 60)
    for w in active:
        target = f" → Target: ${w['target_price']:.2f}" if w['target_price'] else ""
        note = f" ({w['user_note']})" if w['user_note'] else ""
        print(f"  • {w['merchant']}: {w['url'][:50]}...{target}{note}")
    
    if archived:
        print(f"\n🗑️  Archived ({len(archived)})")
        for w in archived:
            reason = w.get('archived_reason', 'unknown')
            print(f"  • {w['merchant']}: {w['url'][:40]}... ({reason})")
    print()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Add a product watch")
    parser.add_argument("url", nargs="?", help="Product URL to watch")
    parser.add_argument("--target", "-t", type=float, help="Target price")
    parser.add_argument("--note", "-n", help="User note/description")
    parser.add_argument("--list", "-l", action="store_true", help="List all watches")
    
    args = parser.parse_args()
    
    if args.list:
        list_watches()
    elif args.url:
        add_watch(args.url, args.target, args.note)
    else:
        parser.print_help()
