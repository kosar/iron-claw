#!/usr/bin/env bash
# setup-daily-report.sh — Install or uninstall the daily report LaunchAgent.
# Usage:
#   ./scripts/setup-daily-report.sh <agent-name> install [--hour H]
#   ./scripts/setup-daily-report.sh <agent-name> uninstall
#   ./scripts/setup-daily-report.sh status

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

HOUR=7
AGENT_ARG=""
ACTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    install|uninstall|status) ACTION="$1"; shift ;;
    --hour) HOUR="$2"; shift 2 ;;
    --*)    echo "Unknown option: $1" >&2; exit 1 ;;
    *)      [[ -z "$AGENT_ARG" ]] && AGENT_ARG="$1"; shift ;;
  esac
done

if [[ "$ACTION" == "status" ]]; then
  echo "Installed daily-report LaunchAgents:"
  ls "$HOME/Library/LaunchAgents/" 2>/dev/null \
    | grep "ai.ironclaw.dailyreport" \
    | while read -r f; do
        label="${f%.plist}"
        loaded=$(launchctl list "$label" 2>/dev/null | awk '/PID/{print "running (PID "$2")"}')
        echo "  $label  ${loaded:-not running}"
      done
  exit 0
fi

if [[ -z "$AGENT_ARG" || -z "$ACTION" ]]; then
  echo "Usage: $0 <agent-name> install [--hour H]" >&2
  echo "       $0 <agent-name> uninstall" >&2
  echo "       $0 status" >&2
  exit 1
fi

resolve_agent "$AGENT_ARG"

PLIST_LABEL="ai.ironclaw.dailyreport.${AGENT_NAME}"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
REPORT_SCRIPT="$SCRIPT_DIR/daily-report.sh"
LOG_STDOUT="$AGENT_LOG_DIR/daily-report.stdout"
LOG_STDERR="$AGENT_LOG_DIR/daily-report.stderr"

if [[ "$ACTION" == "uninstall" ]]; then
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  echo "Uninstalled: $PLIST_LABEL"
  exit 0
fi

# install
mkdir -p "$AGENT_LOG_DIR"

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${REPORT_SCRIPT}</string>
    <string>${AGENT_NAME}</string>
    <string>--save</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>   <integer>${HOUR}</integer>
    <key>Minute</key> <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>${LOG_STDOUT}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_STDERR}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HOME</key>
    <string>${HOME}</string>
  </dict>
</dict>
</plist>
EOF

# Reload
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "Installed: $PLIST_LABEL"
echo "  Schedule: daily at ${HOUR}:00"
echo "  Script:   $REPORT_SCRIPT $AGENT_NAME --save"
echo "  Stdout:   $LOG_STDOUT"
echo "  Stderr:   $LOG_STDERR"
echo "  Plist:    $PLIST_PATH"
echo ""
echo "Test: launchctl start $PLIST_LABEL"
