#!/usr/bin/env python3
"""
ProductWatcher Engine - Core broker/logic script
Triggered by OpenClaw heartbeat/cron

Responsibilities:
- Load active watches from watches.json
- Execute provider strategies (MCP, scraping, APIs)
- Log health metrics for each attempt
- Update market_data.json with price/inventory history
- Emit notifications for significant events only
- Respect waking hours (09:00-21:00)
"""

import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from dataclasses import dataclass, asdict
import urllib.request
import ssl

# Configuration
VAULT_DIR = Path(__file__).parent.parent / "watcher_vault"
WATCHES_FILE = VAULT_DIR / "watches.json"
MARKET_DATA_FILE = VAULT_DIR / "market_data.json"
HEALTH_LOG_FILE = VAULT_DIR / "health_log.json"
SKILL_DIR = Path(__file__).parent.parent

WAKING_HOURS = (9, 21)  # 09:00 - 21:00
NOTIFICATION_COOLDOWN_HOURS = 4
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID") or ""  # Set to your Telegram user ID or from config allowFrom


@dataclass
class WatchEntry:
    """Represents a single product watch"""
    id: str
    url: str
    merchant: str
    target_price: float | None
    track_stock: bool
    enabled: bool
    created_at: str
    last_checked: str | None
    last_notified: str | None
    notify_on: list[str]
    user_note: str
    archived: bool = False
    archived_reason: str | None = None


@dataclass
class HealthEntry:
    """Health log entry for diagnostic tracking"""
    timestamp: str
    watch_id: str
    provider: str
    success: bool
    error_type: str | None
    error_message: str | None
    response_time_ms: int
    strategy_used: str


class WatcherVault:
    """Manages persistent storage for ProductWatcher"""
    
    def __init__(self, vault_dir: Path = VAULT_DIR):
        self.vault_dir = vault_dir
        self.vault_dir.mkdir(parents=True, exist_ok=True)
        self._ensure_files()
    
    def _ensure_files(self):
        """Initialize JSON files if they don't exist"""
        for filepath, default in [
            (WATCHES_FILE, {"watches": [], "preferences": {"notification_channels": ["telegram"], "quiet_mode": False}}),
            (MARKET_DATA_FILE, {"snapshots": []}),
            (HEALTH_LOG_FILE, {"entries": []})
        ]:
            if not filepath.exists():
                filepath.write_text(json.dumps(default, indent=2))
    
    def load_watches(self) -> tuple[list[WatchEntry], dict]:
        """Load active watches and preferences"""
        data = json.loads(WATCHES_FILE.read_text())
        watches = [WatchEntry(**w) for w in data["watches"]]
        return watches, data.get("preferences", {})
    
    def save_watches(self, watches: list[WatchEntry], preferences: dict | None = None):
        """Save watches and preferences"""
        data = json.loads(WATCHES_FILE.read_text())
        data["watches"] = [asdict(w) for w in watches]
        if preferences:
            data["preferences"] = preferences
        WATCHES_FILE.write_text(json.dumps(data, indent=2))
    
    def archive_watch(self, watch_id: str, reason: str):
        """Archive a watch (disable and mark with reason)"""
        watches, prefs = self.load_watches()
        for w in watches:
            if w.id == watch_id:
                w.enabled = False
                w.archived = True
                w.archived_reason = reason
        self.save_watches(watches, prefs)
    
    def add_market_snapshot(self, snapshot: dict):
        """Append market data snapshot"""
        data = json.loads(MARKET_DATA_FILE.read_text())
        data["snapshots"].append(snapshot)
        # Keep only last 90 days of snapshots per watch
        cutoff = datetime.now(timezone.utc).timestamp() - (90 * 24 * 3600)
        data["snapshots"] = [
            s for s in data["snapshots"]
            if datetime.fromisoformat(s["timestamp"]).timestamp() > cutoff
        ]
        MARKET_DATA_FILE.write_text(json.dumps(data, indent=2))
    
    def get_market_history(self, watch_id: str, days: int = 30) -> list[dict]:
        """Get historical snapshots for a watch"""
        data = json.loads(MARKET_DATA_FILE.read_text())
        cutoff = datetime.now(timezone.utc).timestamp() - (days * 24 * 3600)
        snapshots = [
            s for s in data["snapshots"]
            if s["watch_id"] == watch_id and 
               datetime.fromisoformat(s["timestamp"]).timestamp() > cutoff
        ]
        return sorted(snapshots, key=lambda x: x["timestamp"])
    
    def get_all_time_low(self, watch_id: str) -> float | None:
        """Get all-time low price for a watch"""
        data = json.loads(MARKET_DATA_FILE.read_text())
        prices = [
            s["price"] for s in data["snapshots"]
            if s["watch_id"] == watch_id and s["price"] is not None
        ]
        return min(prices) if prices else None
    
    def log_health(self, entry: HealthEntry):
        """Log execution health"""
        data = json.loads(HEALTH_LOG_FILE.read_text())
        data["entries"].append(asdict(entry))
        # Keep last 1000 entries
        data["entries"] = data["entries"][-1000:]
        HEALTH_LOG_FILE.write_text(json.dumps(data, indent=2))
    
    def get_provider_health(self, provider: str, watch_id: str | None = None, limit: int = 10) -> list[HealthEntry]:
        """Get recent health entries for a provider"""
        data = json.loads(HEALTH_LOG_FILE.read_text())
        entries = [
            HealthEntry(**e) for e in data["entries"]
            if e["provider"] == provider and (watch_id is None or e["watch_id"] == watch_id)
        ]
        return entries[-limit:]
    
    def should_skip_provider(self, provider: str, watch_id: str, consecutive_failures_threshold: int = 3) -> bool:
        """Check if provider should be skipped due to repeated failures"""
        recent = self.get_provider_health(provider, watch_id, limit=5)
        if len(recent) < consecutive_failures_threshold:
            return False
        # Check if last N attempts all failed
        return all(not e.success for e in recent[-consecutive_failures_threshold:])
    
    def get_provider_failure_stats(self, provider: str, watch_id: str) -> dict:
        """Get failure statistics for a provider/watch combo"""
        recent = self.get_provider_health(provider, watch_id, limit=10)
        if not recent:
            return {"failures": 0, "error_types": []}
        
        failures = [e for e in recent if not e.success]
        error_types = list(set([e.error_type for e in failures if e.error_type]))
        
        return {
            "failures": len(failures),
            "total_attempts": len(recent),
            "error_types": error_types,
            "last_error": failures[-1].error_message if failures else None
        }


class ProviderEngine:
    """Three-tier provider execution engine with robust error handling"""
    
    def __init__(self, vault: WatcherVault):
        self.vault = vault
        self.providers = {}
        self._load_providers()
    
    def _load_providers(self):
        """Dynamically load provider modules from providers/ directory"""
        providers_dir = SKILL_DIR / "providers"
        if not providers_dir.exists():
            print(f"[WARN] Providers directory not found: {providers_dir}")
            return
        
        for file in providers_dir.glob("*.py"):
            if file.name.startswith("_"):
                continue
            try:
                import importlib.util
                spec = importlib.util.spec_from_file_location(file.stem, file)
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                if hasattr(module, "execute") and hasattr(module, "is_available"):
                    self.providers[file.stem] = module
                    print(f"[INFO] Loaded provider: {file.stem}")
                else:
                    print(f"[WARN] Provider {file.stem} missing required functions")
            except Exception as e:
                print(f"[ERROR] Failed to load provider {file.stem}: {e}")
    
    def _determine_strategies(self, watch: WatchEntry) -> list[tuple[str, callable]]:
        """Determine execution strategy order for a watch"""
        strategies = []
        
        # Tier 1: Merchant-specific strategies
        if watch.merchant == "shopify":
            if "shopify_mcp" in self.providers and self.providers["shopify_mcp"].is_available():
                strategies.append(("shopify_mcp", self.providers["shopify_mcp"].execute))
        
        # Tier 2: General search (Brave Search)
        if "brave_search" in self.providers and self.providers["brave_search"].is_available():
            strategies.append(("brave_search", self.providers["brave_search"].execute))
        
        # Tier 3: Direct scraping (always available)
        if "direct_scrape" in self.providers and self.providers["direct_scrape"].is_available():
            strategies.append(("direct_scrape", self.providers["direct_scrape"].execute))
        
        # Tier 4: Browser automation (JS-heavy / bot-protected sites)
        if "browser_automation" in self.providers and self.providers["browser_automation"].is_available():
            strategies.append(("browser_automation", self.providers["browser_automation"].execute))
        
        # Tier 5: Premium services (Chatsi, etc.)
        for provider_name, module in self.providers.items():
            if provider_name not in ["shopify_mcp", "brave_search", "direct_scrape", "browser_automation"]:
                if module.is_available():
                    strategies.append((provider_name, module.execute))
        
        return strategies
    
    def execute(self, watch: WatchEntry) -> tuple[dict | None, list[dict]]:
        """
        Execute best available provider strategy for a watch.
        
        Returns:
            (snapshot, attempts_log) tuple where:
            - snapshot: MarketSnapshot dict or None if all failed
            - attempts_log: List of attempt results for health tracking
        """
        strategies = self._determine_strategies(watch)
        attempts = []
        
        if not strategies:
            print(f"  [WARN] No providers available for watch {watch.id}")
            return None, []
        
        for strategy_name, provider_func in strategies:
            # Skip if provider has been failing for this watch
            if self.vault.should_skip_provider(strategy_name, watch.id):
                stats = self.vault.get_provider_failure_stats(strategy_name, watch.id)
                print(f"  [SKIP] {strategy_name} (failing {stats['failures']}x, errors: {stats['error_types']})")
                continue
            
            start = time.time()
            try:
                result = provider_func(watch)
                elapsed = int((time.time() - start) * 1000)
                
                if result:
                    # Success - log and return
                    self.vault.log_health(HealthEntry(
                        timestamp=datetime.now(timezone.utc).isoformat(),
                        watch_id=watch.id,
                        provider=strategy_name,
                        success=True,
                        error_type=None,
                        error_message=None,
                        response_time_ms=elapsed,
                        strategy_used=strategy_name
                    ))
                    attempts.append({"provider": strategy_name, "success": True, "time_ms": elapsed})
                    return result, attempts
                else:
                    # Provider returned None (no data available)
                    self.vault.log_health(HealthEntry(
                        timestamp=datetime.now(timezone.utc).isoformat(),
                        watch_id=watch.id,
                        provider=strategy_name,
                        success=False,
                        error_type="NO_DATA",
                        error_message="Provider returned no data",
                        response_time_ms=elapsed,
                        strategy_used=strategy_name
                    ))
                    attempts.append({"provider": strategy_name, "success": False, "error": "NO_DATA"})
                    
            except Exception as e:
                elapsed = int((time.time() - start) * 1000)
                error_type = type(e).__name__
                error_msg = str(e)[:200]
                
                # Log the failure
                self.vault.log_health(HealthEntry(
                    timestamp=datetime.now(timezone.utc).isoformat(),
                    watch_id=watch.id,
                    provider=strategy_name,
                    success=False,
                    error_type=error_type,
                    error_message=error_msg,
                    response_time_ms=elapsed,
                    strategy_used=strategy_name
                ))
                attempts.append({"provider": strategy_name, "success": False, "error": error_type, "message": error_msg})
                print(f"  [FAIL] {strategy_name}: {error_msg}")
        
        # All strategies exhausted
        return None, attempts


class NotificationEngine:
    """Smart notification system - only significant events"""
    
    SIGNIFICANT_EVENTS = ["target_reached", "all_time_low", "back_in_stock"]
    
    def __init__(self, vault: WatcherVault):
        self.vault = vault
    
    def is_waking_hours(self) -> bool:
        """Check if current time is within waking hours"""
        now = datetime.now().hour
        return WAKING_HOURS[0] <= now < WAKING_HOURS[1]
    
    def should_notify(self, watch: WatchEntry, snapshot: dict) -> tuple[bool, str | None, dict]:
        """
        Determine if notification should be sent.
        
        Returns: (should_notify, event_type, context)
        """
        if not self.is_waking_hours():
            return False, None, {}
        
        # Check cooldown
        if watch.last_notified:
            last = datetime.fromisoformat(watch.last_notified)
            hours_since = (datetime.now(timezone.utc) - last).total_seconds() / 3600
            if hours_since < NOTIFICATION_COOLDOWN_HOURS:
                return False, None, {}
        
        context = {
            "watch": asdict(watch),
            "snapshot": snapshot,
            "all_time_low": self.vault.get_all_time_low(watch.id)
        }
        
        price = snapshot.get("price")
        in_stock = snapshot.get("in_stock")
        
        # Event 1: Target price reached
        if watch.target_price and price and price <= watch.target_price:
            if "target_reached" in watch.notify_on:
                return True, "target_reached", context
        
        # Event 2: New all-time low
        atl = context["all_time_low"]
        if price and atl and price < atl:
            if "price_drop" in watch.notify_on:
                return True, "all_time_low", context
        
        # Event 3: Back in stock
        history = self.vault.get_market_history(watch.id, days=7)
        was_out_of_stock = history and all(not s.get("in_stock") for s in history[:-1] if s.get("in_stock") is not None)
        if watch.track_stock and was_out_of_stock and in_stock:
            if "back_in_stock" in watch.notify_on:
                return True, "back_in_stock", context
        
        return False, None, {}
    
    def format_message(self, event_type: str, context: dict) -> str:
        """Format notification message for Telegram"""
        watch = context["watch"]
        snapshot = context["snapshot"]
        
        # Map event types to emojis
        event_emojis = {
            "target_reached": "🎯",
            "all_time_low": "📉",
            "back_in_stock": "📦"
        }
        
        emoji = event_emojis.get(event_type, "🔔")
        title = event_type.replace("_", " ").title()
        
        base = f"{emoji} **{title}**\n\n"
        
        # Product description
        note = watch.get("user_note", "")
        if note:
            base += f"📦 {note}\n"
        else:
            base += f"📦 {watch['url'][:60]}...\n"
        
        # Price info
        price = snapshot.get("price")
        if price:
            base += f"💰 **Current: ${price:.2f}**"
            target = watch.get("target_price")
            if target:
                base += f" (Target: ${target:.2f})"
            base += "\n"
        
        # Stock info
        in_stock = snapshot.get("in_stock")
        if in_stock is not None:
            status = "✅ In Stock" if in_stock else "❌ Out of Stock"
            stock_level = snapshot.get("stock_level")
            if stock_level == "low":
                status += " (Low)"
            base += f"{status}\n"
        
        # All-time low context
        atl = context.get("all_time_low")
        if atl and event_type == "all_time_low":
            base += f"📊 Previous low: ${atl:.2f}\n"
        
        base += f"\n[View Product]({watch['url']})"
        return base
    
    def send_telegram(self, message: str) -> bool:
        """Send notification via Telegram"""
        if not TELEGRAM_BOT_TOKEN:
            print(f"  [WARN] TELEGRAM_BOT_TOKEN not set, skipping notification")
            return False
        
        try:
            url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
            data = json.dumps({
                "chat_id": TELEGRAM_CHAT_ID,
                "text": message,
                "parse_mode": "Markdown",
                "disable_web_page_preview": False
            }).encode("utf-8")
            
            req = urllib.request.Request(
                url,
                data=data,
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            
            ctx = ssl.create_default_context()
            with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
                result = json.loads(resp.read().decode("utf-8"))
                if result.get("ok"):
                    print(f"  [OK] Telegram notification sent")
                    return True
                else:
                    print(f"  [FAIL] Telegram error: {result.get('description')}")
                    return False
                    
        except Exception as e:
            print(f"  [FAIL] Telegram send error: {e}")
            return False


class WatcherEngine:
    """Main engine coordinating all components"""
    
    def __init__(self):
        self.vault = WatcherVault()
        self.providers = ProviderEngine(self.vault)
        self.notifier = NotificationEngine(self.vault)
    
    def run_cycle(self, dry_run: bool = False) -> dict:
        """Execute one full watcher cycle"""
        watches, prefs = self.vault.load_watches()
        active_watches = [w for w in watches if w.enabled and not w.archived]
        
        print(f"[WatcherEngine] Processing {len(active_watches)} active watches")
        
        notifications = []
        failed_watches = []
        
        for watch in active_watches:
            print(f"\n[Processing] {watch.id} ({watch.merchant})")
            
            try:
                # Execute provider strategy
                snapshot, attempts = self.providers.execute(watch)
                
                if snapshot:
                    # Update watch metadata
                    watch.last_checked = datetime.now(timezone.utc).isoformat()
                    self.vault.add_market_snapshot(snapshot)
                    
                    print(f"  [OK] Got data: price=${snapshot.get('price')}, stock={snapshot.get('in_stock')}")
                    
                    # Check for notifications
                    should_notify, event_type, context = self.notifier.should_notify(watch, snapshot)
                    
                    if should_notify:
                        message = self.notifier.format_message(event_type, context)
                        
                        if not dry_run:
                            sent = self.notifier.send_telegram(message)
                            if sent:
                                watch.last_notified = datetime.now(timezone.utc).isoformat()
                                notifications.append({
                                    "watch_id": watch.id,
                                    "event_type": event_type,
                                    "price": snapshot.get("price")
                                })
                        else:
                            print(f"  [DRY-RUN] Would notify: {event_type}")
                            notifications.append({
                                "watch_id": watch.id,
                                "event_type": event_type,
                                "price": snapshot.get("price"),
                                "dry_run": True
                            })
                else:
                    # All providers failed - track this
                    failed_watches.append({
                        "watch_id": watch.id,
                        "url": watch.url,
                        "attempts": attempts
                    })
                    print(f"  [FAIL] All providers failed after {len(attempts)} attempts")
                    
                    # If this is a new watch (no successful checks yet), notify user
                    if not watch.last_checked:
                        if not dry_run:
                            self._notify_new_watch_no_data(watch)
                        else:
                            print(f"  [DRY-RUN] Would notify: Added to watchlist, no data yet")
                    
            except Exception as e:
                print(f"  [ERROR] Unexpected error processing watch {watch.id}: {e}")
                failed_watches.append({
                    "watch_id": watch.id,
                    "error": str(e)
                })
        
        # Save updated watch states
        self.vault.save_watches(watches, prefs)
        
        return {
            "processed": len(active_watches),
            "successful": len(active_watches) - len(failed_watches),
            "failed": len(failed_watches),
            "notifications": notifications,
            "failed_watches": failed_watches,
            "timestamp": datetime.now(timezone.utc).isoformat()
        }
    
    def _notify_new_watch_no_data(self, watch: WatchEntry):
        """Notify user that a new watch was added but data isn't available yet"""
        message = (
            f"📋 **Added to Watchlist**\n\n"
            f"📦 {watch.user_note or watch.url}\n"
            f"💡 I'm monitoring this product but haven't found pricing data yet. "
            f"I'll keep trying different methods and let you know when I find something.\n\n"
            f"[View Product]({watch.url})"
        )
        self.notifier.send_telegram(message)
    
    def get_status(self) -> dict:
        """Get comprehensive status report"""
        watches, prefs = self.vault.load_watches()
        
        active = [w for w in watches if w.enabled and not w.archived]
        archived = [w for w in watches if w.archived]
        
        # Health stats
        health = json.loads(HEALTH_LOG_FILE.read_text())
        recent = health["entries"][-50:]
        
        success_by_provider = {}
        for entry in recent:
            provider = entry["provider"]
            if provider not in success_by_provider:
                success_by_provider[provider] = {"success": 0, "fail": 0}
            if entry["success"]:
                success_by_provider[provider]["success"] += 1
            else:
                success_by_provider[provider]["fail"] += 1
        
        return {
            "active_watches": len(active),
            "archived_watches": len(archived),
            "providers_loaded": list(self.providers.providers.keys()),
            "provider_health": {
                name: {
                    "success_rate": stats["success"] / (stats["success"] + stats["fail"]) if (stats["success"] + stats["fail"]) > 0 else 0,
                    "total": stats["success"] + stats["fail"]
                }
                for name, stats in success_by_provider.items()
            },
            "is_waking_hours": self.notifier.is_waking_hours(),
            "next_check": "Top of hour" if self.notifier.is_waking_hours() else "09:00 UTC"
        }


def main():
    """CLI entry point"""
    import argparse
    parser = argparse.ArgumentParser(description="ProductWatcher Engine")
    parser.add_argument("--dry-run", action="store_true", help="Run without sending notifications")
    parser.add_argument("--status", action="store_true", help="Show watcher status")
    parser.add_argument("--test-telegram", action="store_true", help="Test Telegram notification")
    args = parser.parse_args()
    
    engine = WatcherEngine()
    
    if args.status:
        status = engine.get_status()
        print(json.dumps(status, indent=2))
        return
    
    if args.test_telegram:
        notifier = NotificationEngine(engine.vault)
        test_msg = "🧪 **Test Notification**\n\nProductWatcher is configured correctly!"
        notifier.send_telegram(test_msg)
        return
    
    result = engine.run_cycle(dry_run=args.dry_run)
    print("\n" + "="*60)
    print("Cycle Complete")
    print("="*60)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
