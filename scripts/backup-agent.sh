#!/usr/bin/env bash
# backup-agent.sh — Create a timestamped archive of an agent's state (config-runtime, logs).
# Does not include .env or any secrets.
#
# Usage: ./scripts/backup-agent.sh <agent-name> [--output-dir <dir>]
#
# Archive: agents/<name>/backups/<name>-YYYYMMDD-HHMMSS.tar.gz (or under --output-dir).
# Restore: extract archive into agent dir, restore .env manually, then compose-up.

set -e
source "$(dirname "$0")/lib.sh"

OUTPUT_DIR=""
NAME_ARG="${1:?Usage: $0 <agent-name> [--output-dir <dir>]}"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="${2:?Missing argument for --output-dir}"
      shift 2
      ;;
    *)
      echo "Error: Unknown option '$1'" >&2
      echo "Usage: $0 <agent-name> [--output-dir <dir>]" >&2
      exit 1
      ;;
  esac
done

resolve_agent "$NAME_ARG"

if [[ -z "$OUTPUT_DIR" ]]; then
  BACKUP_ROOT="$AGENT_DIR/backups"
else
  BACKUP_ROOT="$OUTPUT_DIR"
fi
mkdir -p "$BACKUP_ROOT"

STAMP=$(date +%Y%m%d-%H%M%S)
ARCHIVE_NAME="${AGENT_NAME}-${STAMP}.tar.gz"
ARCHIVE_PATH="$BACKUP_ROOT/$ARCHIVE_NAME"
MANIFEST=$(mktemp)
trap 'rm -f "$MANIFEST"' EXIT

# Manifest for the archive
{
  echo "agent=$AGENT_NAME"
  echo "timestamp=$STAMP"
  echo "paths=config-runtime logs"
  echo "created=$(date -Iseconds 2>/dev/null || date)"
} > "$MANIFEST"

TAR_DIR=$(mktemp -d)
trap 'rm -rf "$TAR_DIR" "$MANIFEST"' EXIT
mkdir -p "$TAR_DIR/manifest"
cp "$MANIFEST" "$TAR_DIR/manifest/backup-manifest.txt"

# Copy only what we back up (do not follow symlinks; exclude .env)
if [[ -d "$AGENT_CONFIG_RUNTIME" ]]; then
  cp -a "$AGENT_CONFIG_RUNTIME" "$TAR_DIR/config-runtime"
fi
if [[ -d "$AGENT_LOG_DIR" ]]; then
  cp -a "$AGENT_LOG_DIR" "$TAR_DIR/logs"
fi

# Create archive from TAR_DIR (no .env is present there)
(cd "$TAR_DIR" && tar czf "$ARCHIVE_PATH" .)
echo "Backup written: $ARCHIVE_PATH"
