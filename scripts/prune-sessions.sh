#!/usr/bin/env bash
# Prune session JSONL files to prevent unbounded growth from heartbeats.
#
# Keeps: lines 1-4 (session header, model_change, thinking_level_change, model-snapshot)
#        + the last 50 message lines
# Deletes: everything between the header block and the last 50 messages
#
# Only prunes files larger than 80KB. Creates .bak backups before pruning.
#
# Usage:
#   ./scripts/prune-sessions.sh <agent-name>           # prune all sessions
#   ./scripts/prune-sessions.sh <agent-name> --dry-run # show what would be pruned

set -e
source "$(dirname "$0")/lib.sh"
resolve_agent "$1"; shift

SESSIONS_DIR="$AGENT_CONFIG_RUNTIME/agents/main/sessions"
THRESHOLD_KB=80
HEADER_LINES=4
KEEP_TAIL=50
DRY_RUN=false

if [[ "$1" == "--dry-run" ]]; then
  DRY_RUN=true
fi

if [[ ! -d "$SESSIONS_DIR" ]]; then
  echo "[$AGENT_NAME] No sessions directory found at $SESSIONS_DIR — nothing to prune."
  exit 0
fi

pruned=0
skipped=0

for f in "$SESSIONS_DIR"/*.jsonl; do
  [[ -f "$f" ]] || continue

  size_kb=$(( $(wc -c < "$f") / 1024 ))
  if (( size_kb < THRESHOLD_KB )); then
    skipped=$((skipped + 1))
    continue
  fi

  total_lines=$(wc -l < "$f")
  # Need more lines than header + tail to be worth pruning
  if (( total_lines <= HEADER_LINES + KEEP_TAIL )); then
    skipped=$((skipped + 1))
    continue
  fi

  basename=$(basename "$f")
  tail_start=$(( total_lines - KEEP_TAIL + 1 ))

  if [[ "$DRY_RUN" == true ]]; then
    removed=$(( total_lines - HEADER_LINES - KEEP_TAIL ))
    echo "[dry-run] $basename: ${size_kb}KB, ${total_lines} lines → would keep ${HEADER_LINES} header + ${KEEP_TAIL} tail, remove ${removed} lines"
    pruned=$((pruned + 1))
    continue
  fi

  # Create backup
  cp "$f" "${f}.bak"

  # Build pruned file: header lines + last N lines
  tmp=$(mktemp)
  head -n "$HEADER_LINES" "$f" > "$tmp"
  tail -n "$KEEP_TAIL" "$f" >> "$tmp"

  # Validate: first line must be the session header
  if head -1 "$tmp" | grep -q '"type":"session"'; then
    new_lines=$(wc -l < "$tmp")
    removed=$(( total_lines - new_lines ))
    mv "$tmp" "$f"
    # Remove backup on success
    rm -f "${f}.bak"
    echo "[$AGENT_NAME] Pruned $basename: ${total_lines} → ${new_lines} lines (removed ${removed}), saved $(( size_kb - $(wc -c < "$f") / 1024 ))KB"
    pruned=$((pruned + 1))
  else
    echo "[$AGENT_NAME] ERROR: Pruned file for $basename missing session header — restoring backup"
    mv "${f}.bak" "$f"
    rm -f "$tmp"
  fi
done

echo "[$AGENT_NAME] Session pruning complete: ${pruned} pruned, ${skipped} skipped (under ${THRESHOLD_KB}KB)"
