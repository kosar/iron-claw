#!/bin/bash
# Install the iMessage sender service as a user LaunchAgent.
# Run once: ./scripts/setup-imessage-sender.sh
# Uninstall: ./scripts/setup-imessage-sender.sh --uninstall

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.ironclaw.imessage-sender"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
PYTHON_SCRIPT="$SCRIPT_DIR/imessage-sender.py"
LOG_DIR="$HOME/Library/Logs/ironclaw"

if [[ "${1:-}" == "--uninstall" ]]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "iMessage sender service uninstalled."
    exit 0
fi

mkdir -p "$LOG_DIR"

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>${PYTHON_SCRIPT}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>IMESSAGE_SENDER_SECRET</key>
        <string>openclaw</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/imessage-sender.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/imessage-sender.log</string>
</dict>
</plist>
EOF

# Unload existing instance if running
launchctl unload "$PLIST_PATH" 2>/dev/null || true

# Load the new plist
launchctl load "$PLIST_PATH"

echo "iMessage sender service installed and started."
echo "  Port:    18799"
echo "  Log:     $LOG_DIR/imessage-sender.log"
echo "  Plist:   $PLIST_PATH"
echo ""
echo "Test: curl -s http://localhost:18799/health"
