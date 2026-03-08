#!/bin/bash
# ProductWatcher Cron Setup
# Run this script to add the ProductWatcher to your system crontab

echo "Setting up ProductWatcher cron job..."

# Create log directory
mkdir -p /home/openclaw/.openclaw/workspace/skills/productwatcher/watcher_vault/logs

# Add to crontab (runs every hour)
CRON_LINE="0 * * * * cd /home/openclaw/.openclaw/workspace/skills/productwatcher && /usr/bin/python3 scripts/watcher_engine.py >> watcher_vault/logs/cron-\$(date +\%Y\%m\%d).log 2>&1"

# Check if already exists
if crontab -l 2>/dev/null | grep -q "watcher_engine.py"; then
    echo "ProductWatcher cron job already exists."
    echo ""
    echo "To remove it, run: crontab -e and delete the line containing 'watcher_engine.py'"
else
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    echo "✅ ProductWatcher cron job added!"
    echo "   Runs every hour at :00"
    echo "   Logs: watcher_vault/logs/cron-YYYYMMDD.log"
fi

echo ""
echo "Manual test commands:"
echo "  Check status:  python3 scripts/watcher_engine.py --status"
echo "  Dry run:       python3 scripts/watcher_engine.py --dry-run"
echo "  Test Telegram: python3 scripts/watcher_engine.py --test-telegram"
