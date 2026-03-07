#!/usr/bin/env bash
# heal-sessions.sh — Strip trailing incomplete assistant messages from session JSONL files.
#
# Background: gpt-5-mini always generates thinking/reasoning items (thinkingSignature).
# When a run fails mid-execution or the channel fails to deliver the reply, sessions
# accumulate reasoning items that cause OpenAI 400 errors on replay:
#   "reasoning item provided without its required following item"
#   "message provided without its required reasoning item"
#
# Usage:
#   ./scripts/heal-sessions.sh ironclaw-bot
#   ./scripts/heal-sessions.sh --all
#   ./scripts/heal-sessions.sh --all --aggressive          (wipe .reset.* files)
#   ./scripts/heal-sessions.sh --all --aggressive --startup (also wipe sessions with thinkingSignature)
#   ./scripts/heal-sessions.sh --all --quiet   (suppress "no damage found" lines)
#
# --startup: used by compose-up.sh only. Container is stopped so no active writes.
#   Wipes any session with accumulated thinkingSignature items (gpt-5-mini reasoning).
#   These sessions will 400 on the next run due to OpenClaw's replay bug with reasoning models.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

QUIET=false
VERBOSE=false
AGGRESSIVE=false
STARTUP=false
ALL_AGENTS=false
TARGET_AGENT=""

# Parse args
for arg in "$@"; do
  case "$arg" in
    --all)    ALL_AGENTS=true ;;
    --quiet)  QUIET=true ;;
    --verbose) VERBOSE=true ;;
    --aggressive) AGGRESSIVE=true ;;
    --startup) STARTUP=true ;;
    --*)      echo "Unknown flag: $arg" >&2; exit 1 ;;
    *)        TARGET_AGENT="$arg" ;;
  esac
done

if [[ "$ALL_AGENTS" == false && -z "$TARGET_AGENT" ]]; then
  echo "Usage: $0 <agent-name> | --all [--quiet] [--aggressive] [--startup]" >&2
  exit 1
fi

# Inline Python3 healer — takes arguments: path to the sessions directory and flags
PYTHON_HEALER=$(cat << 'PYEOF'
import sys
import os
import json
import time

sessions_dir = sys.argv[1]
quiet = "--quiet" in sys.argv
verbose = "--verbose" in sys.argv
aggressive = "--aggressive" in sys.argv
startup = "--startup" in sys.argv  # only passed by compose-up.sh; container is stopped

def is_incomplete_assistant(obj):
    """Returns True if role=assistant and content is empty or only thinking items."""
    if obj.get("type") != "message":
        return False
    msg = obj.get("message", {})
    if msg.get("role") != "assistant":
        return False
    content = msg.get("content", [])
    if len(content) == 0:
        return True
    for item in content:
        if item.get("type") not in ("thinking",):
            return False
    return True

def is_thinking_level_change(obj):
    return obj.get("type") == "thinking_level_change"

def ends_with_unanswered_user(entries):
    """Returns True if the last substantive message is role=user with no assistant reply.
    This catches sessions stuck mid-heartbeat: the cron fires, injects a user message,
    but the run fails before the agent replies. On replay OpenClaw gets a 400 because
    the prior run left stale in-memory tool state that isn't in the JSONL anymore.
    Only fires on sessions with >5 lines of history (not brand-new sessions).
    """
    if len(entries) < 6:
        return False
    for _, _, obj in reversed(entries):
        if obj.get("type") != "message":
            continue
        msg = obj.get("message", {}) if isinstance(obj.get("message"), dict) else {}
        role = msg.get("role", "")
        if role == "user":
            return True
        if role == "assistant":
            return False
    return False

def has_thinking_signature(obj):
    """Returns True if this message has any thinkingSignature content item."""
    if obj.get("type") != "message":
        return False
    content = obj.get("message", {}).get("content", [])
    return any(isinstance(item, dict) and item.get("thinkingSignature") for item in content)

def wipe_to_header(filepath):
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            first_line = f.readline()
        if not first_line or '"type"' not in first_line or '"session"' not in first_line:
            return False
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(first_line.rstrip("\n") + "\n")
        print(f"Aggressive wipe: {filepath} (preserved header)", flush=True)
        return True
    except Exception as e:
        print(f"WARNING: Failed to wipe {filepath}: {e}", flush=True)
        return False

def get_entries(filepath):
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            lines = f.readlines()
        entries = []
        for i, line in enumerate(lines):
            line = line.strip()
            if not line: continue
            entries.append((i, line, json.loads(line)))
        return entries
    except Exception:
        return None

def heal_file(filepath):
    entries = get_entries(filepath)
    if not entries or len(entries) <= 1:
        return

    # Startup wipe: at compose-up time (container stopped, no active writes),
    # wipe any session that has accumulated thinkingSignature items. These will
    # 400 on the next run because OpenClaw's replay strips thinkingSignatures
    # but OpenAI then sees messages without their required preceding reasoning items.
    if startup and any(has_thinking_signature(e[2]) for e in entries):
        wipe_to_header(filepath)
        return

    # Phase 1b: wipe sessions that end with an unanswered user message (stuck mid-run).
    # Uses a 5-minute staleness guard — much more conservative than the 90s phase-1 guard —
    # because a legitimate run could take several minutes before producing a reply.
    # Only applied to files that are not fresh (checked by the caller's 90s recency guard
    # before calling heal_file). Here we add an extra 5-min check for safety.
    if ends_with_unanswered_user(entries):
        try:
            age = time.time() - os.path.getmtime(filepath)
        except OSError:
            age = 0
        if age > 300:  # 5 minutes
            if wipe_to_header(filepath):
                # Signal to the bash wrapper that a Phase 1b wipe occurred.
                # The bash wrapper will restart the container so OpenClaw reloads
                # from disk — wiping the JSONL alone doesn't clear in-memory state.
                print(f"PHASE1B_WIPE: {filepath}", flush=True)
            return

    # Phase 1: remove trailing incomplete assistant messages
    original_len = len(entries)
    removed = 0
    while len(entries) > 1 and is_incomplete_assistant(entries[-1][2]):
        entries.pop()
        removed += 1
    if removed > 0 and len(entries) > 1 and is_thinking_level_change(entries[-1][2]):
        entries.pop()
        removed += 1

    if removed > 0:
        if not os.access(filepath, os.W_OK):
            print(f"WARNING: {filepath} is not writable", flush=True)
            return
        surviving_raw = [raw for (_, raw, _) in entries]
        with open(filepath, "w", encoding="utf-8") as f:
            for raw_line in surviving_raw:
                f.write(raw_line.rstrip("\n") + "\n")
        print(f"Healed {filepath}: removed {removed} trailing line{'s' if removed != 1 else ''}", flush=True)

if not os.path.isdir(sessions_dir):
    sys.exit(0)

# Group files by session ID
files_by_id = {}
for fname in os.listdir(sessions_dir):
    fpath = os.path.join(sessions_dir, fname)
    if not os.path.isfile(fpath): continue
    
    if fname.endswith(".jsonl"):
        sid = fname
        d = files_by_id.setdefault(sid, {"jsonl": None, "resets": [], "baks": []})
        d["jsonl"] = fpath
    elif ".reset." in fname:
        sid = fname.split(".reset.")[0]
        d = files_by_id.setdefault(sid, {"jsonl": None, "resets": [], "baks": []})
        if fname.endswith(".bak"):
            d["baks"].append(fpath)
        else:
            d["resets"].append(fpath)

# Process each session
for sid, info in files_by_id.items():
    # Trigger Phase 2: .reset file presence
    if aggressive and info["resets"]:
        if info["jsonl"]: wipe_to_header(info["jsonl"])
        for r in info["resets"]: wipe_to_header(r)
    else:
        # Phase 1: strip trailing incomplete assistant messages
        if info["jsonl"]:
            # Skip files modified in the last 90s — may be actively written mid-run
            try:
                if time.time() - os.path.getmtime(info["jsonl"]) < 90:
                    continue
            except OSError:
                pass
            heal_file(info["jsonl"])
        elif info["resets"]:
            # Orphaned reset files (no matching .jsonl) — apply Phase 1
            for r in sorted(info["resets"]):
                heal_file(r)

    # Cleanup backups
    bak_limit = 3600 if aggressive else 7 * 24 * 3600
    now = time.time()
    for b in info["baks"]:
        try:
            if now - os.path.getmtime(b) > bak_limit:
                os.remove(b)
                if not quiet: print(f"Deleted stale backup: {b}", flush=True)
        except OSError: pass
PYEOF
)

heal_agent() {
  local name="$1"
  resolve_agent "$name"

  if [[ ! -d "$AGENT_SESSIONS" ]]; then
    if [[ "$QUIET" == false ]]; then
      echo "[$name] No sessions directory found — skipping"
    fi
    return 0
  fi

  local extra_flags=""
  [[ "$QUIET" == true ]] && extra_flags="$extra_flags --quiet"
  [[ "$VERBOSE" == true ]] && extra_flags="$extra_flags --verbose"
  [[ "$AGGRESSIVE" == true ]] && extra_flags="$extra_flags --aggressive"
  [[ "$STARTUP" == true ]] && extra_flags="$extra_flags --startup"

  # Capture output so we can detect Phase 1b wipes and trigger a container restart.
  local output
  output=$(python3 -c "$PYTHON_HEALER" "$AGENT_SESSIONS" $extra_flags 2>&1)
  [[ -n "$output" ]] && echo "$output"

  # If Phase 1b wiped a stuck heartbeat session, restart the container so OpenClaw
  # reloads from disk. Wiping the JSONL alone doesn't work — OpenClaw holds the bad
  # tool-call state in memory and keeps replaying it until restarted.
  if echo "$output" | grep -q "^PHASE1B_WIPE:"; then
    local started started_epoch now_epoch uptime_secs
    started=$(docker inspect --format '{{.State.StartedAt}}' "$AGENT_CONTAINER" 2>/dev/null || echo "")
    if [[ -z "$started" ]]; then
      echo "[$name] Container $AGENT_CONTAINER not found — skipping restart"
      return 0
    fi
    # BSD date (macOS): strip fractional seconds for parsing
    started_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${started%%.*}" "+%s" 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    uptime_secs=$(( now_epoch - started_epoch ))
    if [[ $uptime_secs -lt 600 ]]; then
      echo "[$name] Container started ${uptime_secs}s ago — skipping restart (cooldown)"
    else
      echo "[$name] Phase 1b wipe — restarting $AGENT_CONTAINER to reload clean session state..."
      docker restart "$AGENT_CONTAINER" >/dev/null 2>&1 \
        && echo "[$name] $AGENT_CONTAINER restarted OK" \
        || echo "[$name] WARNING: docker restart $AGENT_CONTAINER failed"
    fi
  fi
}

# Main
if [[ "$ALL_AGENTS" == true ]]; then
  IRONCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  while IFS= read -r name; do
    heal_agent "$name" || true
  done < <(list_agent_dirs)
else
  heal_agent "$TARGET_AGENT" || true
fi

exit 0
