#!/usr/bin/env bash
# setup-session-healer.sh — Install/uninstall/status a LaunchAgent that runs
# heal-sessions.sh --all --quiet on a periodic interval.
#
# Usage:
#   ./scripts/setup-session-healer.sh install [--interval-seconds N]  # default: 300
#   ./scripts/setup-session-healer.sh uninstall
#   ./scripts/setup-session-healer.sh status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IRONCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PLIST_LABEL="ai.ironclaw.session-healer"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
HEALER_SCRIPT="$IRONCLAW_ROOT/scripts/heal-sessions.sh"
LOG_DIR="$IRONCLAW_ROOT/logs"
LOG_FILE="$LOG_DIR/session-healer.log"

DEFAULT_INTERVAL=30

usage() {
  echo "Usage:"
  echo "  $0 install [--interval-seconds N]   # default: ${DEFAULT_INTERVAL}s"
  echo "  $0 uninstall"
  echo "  $0 status"
  exit 1
}

cmd="${1:-}"
[[ -z "$cmd" ]] && usage

case "$cmd" in
  install)
    INTERVAL=$DEFAULT_INTERVAL
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --interval-seconds)
          shift
          INTERVAL="${1:?--interval-seconds requires a value}"
          ;;
        *)
          echo "Unknown option: $1" >&2
          usage
          ;;
      esac
      shift
    done

    # Validate interval is a positive integer
    if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [[ "$INTERVAL" -lt 1 ]]; then
      echo "Error: --interval-seconds must be a positive integer" >&2
      exit 1
    fi

    # Ensure healer script exists
    if [[ ! -f "$HEALER_SCRIPT" ]]; then
      echo "Error: Healer script not found: $HEALER_SCRIPT" >&2
      exit 1
    fi

    # Ensure log directory exists
    mkdir -p "$LOG_DIR"

    # Unload existing agent if present (ignore errors)
    if launchctl list "$PLIST_LABEL" &>/dev/null; then
      echo "Unloading existing LaunchAgent..."
      launchctl unload "$PLIST_PATH" 2>/dev/null || true
    fi

    # Write the plist
    cat > "$PLIST_PATH" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${HEALER_SCRIPT}</string>
        <string>--all</string>
        <string>--quiet</string>
        <string>--aggressive</string>
    </array>

    <key>StartInterval</key>
    <integer>${INTERVAL}</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>

    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>

    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
</dict>
</plist>
PLIST_EOF

    echo "Wrote plist: $PLIST_PATH"

    # Load the agent
    launchctl load "$PLIST_PATH"
    echo "LaunchAgent installed and loaded."
    echo "  Label:    $PLIST_LABEL"
    echo "  Interval: ${INTERVAL}s"
    echo "  Log:      $LOG_FILE"
    echo ""
    echo "Run '$0 status' to verify."
    ;;

  uninstall)
    if [[ ! -f "$PLIST_PATH" ]]; then
      echo "LaunchAgent plist not found: $PLIST_PATH"
      echo "Nothing to uninstall."
      exit 0
    fi

    if launchctl list "$PLIST_LABEL" &>/dev/null; then
      launchctl unload "$PLIST_PATH"
      echo "LaunchAgent unloaded."
    else
      echo "LaunchAgent was not loaded."
    fi

    rm -f "$PLIST_PATH"
    echo "Removed plist: $PLIST_PATH"
    echo "LaunchAgent uninstalled."
    ;;

  status)
    echo "Label:     $PLIST_LABEL"
    echo "Plist:     $PLIST_PATH"
    echo "Log:       $LOG_FILE"
    echo ""

    if [[ -f "$PLIST_PATH" ]]; then
      echo "Plist file: EXISTS"
    else
      echo "Plist file: NOT FOUND (not installed)"
    fi

    echo ""
    if launchctl list "$PLIST_LABEL" 2>/dev/null; then
      echo "LaunchAgent: LOADED"
    else
      echo "LaunchAgent: NOT LOADED"
    fi

    if [[ -f "$LOG_FILE" ]]; then
      echo ""
      echo "--- Last 20 lines of $LOG_FILE ---"
      tail -n 20 "$LOG_FILE"
    fi
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    usage
    ;;
esac
