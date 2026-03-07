#!/usr/bin/env bash
# bash 3 compatible (no associative arrays)
# OpenClaw log analysis: server-side failure detection and optional session-reply scanning.
# Requires jq.
#
# Usage:
#   ./scripts/analyze-logs.sh <agent-name> [OPTIONS]
#
# Options:
#   --last N       Scan last N log lines (default 2000)
#   --days D       Scan last D days of log files (default: today only)
#   --all          Scan full current-day log
#   --replies      Also scan assistant messages in session JSONL for failure phrases
#   --no-summary   Skip category summary
#   --category C   Only show category C: auth|tool|network|provider|error (default: all)
#   --verbose      Print raw message when it's an object

set -e
source "$(dirname "$0")/lib.sh"
resolve_agent "$1"; shift

LOG_DIR="$AGENT_LOG_DIR"
SESSIONS_DIR="$AGENT_SESSIONS"

# Defaults
LINES=2000
DAYS=0
MODE="server"
REPLIES=false
SUMMARY=true
CATEGORY=""
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --last)   LINES="$2"; shift 2 ;;
    --days)   DAYS="$2";  shift 2 ;;
    --all)    LINES="";   shift ;;   # empty => cat whole file
    --replies) REPLIES=true; shift ;;
    --no-summary) SUMMARY=false; shift ;;
    --category) CATEGORY="$2"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required. Install with: brew install jq" >&2
  exit 1
fi

# Category patterns (server log message)
PAT_AUTH='API key|api key|apiKey|missing.*key|unauthorized|401|403|authentication|auth failed|invalid.*token|OPENWEATHER|weather.*key'
PAT_TOOL='tool.*fail|action.*fail|tool error|action error|skill.*fail|not configured|not available|missing config'
PAT_NETWORK='ECONNREFUSED|ETIMEDOUT|ENOTFOUND|timeout|connection refused|network error|fetch failed'
PAT_PROVIDER='openai.*error|ollama.*error|rate limit|429|model.*unavailable|provider.*fail'
PAT_ERROR='\berror\b|Error|exception|failed|Failure|ECONNREFUSED|ETIMEDOUT'

# Combined pattern for grep (all categories)
ALL_PAT="API key|api key|apiKey|missing.*key|unauthorized|401|403|authentication|auth failed|invalid.*token|OPENWEATHER|weather.*key|tool.*fail|action.*fail|tool error|action error|skill.*fail|not configured|not available|missing config|ECONNREFUSED|ETIMEDOUT|ENOTFOUND|timeout|connection refused|network error|fetch failed|openai.*error|ollama.*error|rate limit|429|model.*unavailable|provider.*fail|\berror\b|Error|exception|failed|Failure"

# Reply-side phrases (agent said it couldn't do something)
REPLY_PAT="can't|cannot|couldn't|could not|don't have|do not have|missing API key|no API key|not configured|not available|unable to|I can't|I cannot|we don't have|there is no|there isn't|is not set|hasn't been set|need.*key|required.*key|please set|add.*key|get a key"

get_category() {
  local msg="$1"
  if [[ -n "$CATEGORY" ]]; then
    case "$CATEGORY" in
      auth)     echo "$msg" | grep -qiE "$PAT_AUTH"    && echo "auth"     ;;
      tool)     echo "$msg" | grep -qiE "$PAT_TOOL"    && echo "tool"     ;;
      network)  echo "$msg" | grep -qiE "$PAT_NETWORK" && echo "network"  ;;
      provider) echo "$msg" | grep -qiE "$PAT_PROVIDER" && echo "provider" ;;
      error)    echo "$msg" | grep -qiE "$PAT_ERROR" && echo "error"    ;;
      *)        : ;;
    esac
    return
  fi
  echo "$msg" | grep -qiE "$PAT_AUTH"    && { echo "auth";     return; }
  echo "$msg" | grep -qiE "$PAT_TOOL"    && { echo "tool";     return; }
  echo "$msg" | grep -qiE "$PAT_NETWORK" && { echo "network";  return; }
  echo "$msg" | grep -qiE "$PAT_PROVIDER" && { echo "provider"; return; }
  echo "$msg" | grep -qiE "$PAT_ERROR" && { echo "error";    return; }
  echo "other"
}

# ---- Server-side ----
run_server_analysis() {
  local log_files=()
  if [[ $DAYS -gt 0 ]]; then
    for ((d=0; d<=DAYS; d++)); do
      local dte
      dte=$(date -v-${d}d +%Y-%m-%d 2>/dev/null || date -d "-${d} days" +%Y-%m-%d 2>/dev/null)
      [[ -f "$LOG_DIR/openclaw-$dte.log" ]] && log_files+=("$LOG_DIR/openclaw-$dte.log")
    done
  else
    local latest
    latest=$(ls -t "$LOG_DIR"/openclaw-*.log 2>/dev/null | head -1)
    [[ -z "$latest" ]] && { echo "No openclaw-*.log in $LOG_DIR/" >&2; return 1; }
    log_files=("$latest")
  fi

  local input_cmd
  if [[ -z "$LINES" ]]; then
    input_cmd="cat ${log_files[*]}"
  else
    input_cmd="tail -n $LINES ${log_files[0]}"
  fi

  count_auth=0
  count_tool=0
  count_network=0
  count_provider=0
  count_error=0
  count_other=0

  echo "=== Server log analysis ($AGENT_NAME) ==="
  echo "Source: ${log_files[*]} ${LINES:+ (last $LINES lines)}"
  echo "---"

  while IFS= read -r line; do
    if ! echo "$line" | jq -e . >/dev/null 2>&1; then continue; fi
    local msg
    msg=$(echo "$line" | jq -r '
      (.["msg"] // .["message"] // .["1"]) | if type == "string" then . else (. | tostring) end
    ' 2>/dev/null) || msg=""
    [[ -z "$msg" || "$msg" == "null" ]] && continue
    if ! echo "$msg" | grep -qiE "$ALL_PAT"; then continue; fi

    local time level cat
    time=$(echo "$line" | jq -r '.time // ._meta.date // ""')
    level=$(echo "$line" | jq -r '._meta.logLevelName // "?"')
    cat=$(get_category "$msg")
    [[ -z "$cat" ]] && { [[ -n "$CATEGORY" ]] && continue; cat="other"; }

    case "$cat" in
      auth)     count_auth=$((count_auth + 1)) ;;
      tool)     count_tool=$((count_tool + 1)) ;;
      network)  count_network=$((count_network + 1)) ;;
      provider) count_provider=$((count_provider + 1)) ;;
      error)    count_error=$((count_error + 1)) ;;
      other)    count_other=$((count_other + 1)) ;;
    esac

    local msg_show="$msg"
    [[ ${#msg_show} -gt 200 ]] && msg_show="${msg_show:0:197}..."
    printf "%s | %-5s | %-8s | %s\n" "$time" "$level" "$cat" "$msg_show"
  done < <(eval "$input_cmd")

  if [[ "$SUMMARY" == true ]]; then
    echo "---"
    echo "Summary (count by category):"
    printf "  auth: %s  tool: %s  network: %s  provider: %s  error: %s  other: %s\n" \
      "$count_auth" "$count_tool" "$count_network" \
      "$count_provider" "$count_error" "$count_other"
  fi
}

# ---- Session replies (assistant message content) ----
run_reply_scan() {
  echo ""
  echo "=== Session reply scan ($AGENT_NAME — assistant messages containing failure-like phrases) ==="
  echo "Patterns: $REPLY_PAT"
  echo "---"

  for f in "$SESSIONS_DIR"/*.jsonl; do
    [[ -f "$f" ]] || continue
    local session_id
    session_id=$(basename "$f" .jsonl)
    local turn=0
    while IFS= read -r line; do
      local role
      role=$(echo "$line" | jq -r '.message.role // empty')
      [[ "$role" != "assistant" ]] && continue
      (( turn++ )) || true
      local ts content
      ts=$(echo "$line" | jq -r '.message.timestamp // .timestamp // ""')
      content=$(echo "$line" | jq -r '
        .message.content // []
        | if type == "array" then
            [.[] | select(.text?) | .text] | join(" ")
          else . end
        | if type != "string" then "" else . end
      ' 2>/dev/null)
      [[ -z "$content" ]] && continue
      if ! echo "$content" | grep -qiE "$REPLY_PAT"; then continue; fi
      local snippet="${content:0:300}"
      [[ ${#content} -gt 300 ]] && snippet="${snippet}..."
      echo "session=$session_id turn=$turn ts=$ts"
      echo "  $snippet"
      echo ""
    done < "$f"
  done
}

# Run
if [[ "$MODE" == "server" ]] || [[ "$REPLIES" != true ]]; then
  run_server_analysis
fi
if [[ "$REPLIES" == true ]]; then
  run_reply_scan
fi
