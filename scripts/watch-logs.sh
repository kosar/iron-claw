#!/usr/bin/env bash
# OpenClaw live log monitor — informative view for 80-120 col terminals.
# Shows agent requests, LLM calls, tool usage, token costs, and errors.
# Also monitors Shopify Nexus MCP calls (nexus-search.log).
# Usage: ./scripts/watch-logs.sh [agent-name | --all]

set -e
source "$(dirname "$0")/lib.sh"

# ── Color shortcuts ──
C_RST=$'\033[0m'
C_GRN=$'\033[1;32m'    # RUN start, DONE
C_MAG=$'\033[35m'       # LLM/prompt activity
C_YEL=$'\033[33m'       # tools, cost
C_CYN=$'\033[36m'       # queue, lane, config, MCP
C_RED=$'\033[1;31m'     # errors, abort
C_DIM=$'\033[2m'        # secondary info
C_BMAG=$'\033[1;35m'    # Nexus pipeline events
C_CMD=$'\033[90m'       # dark gray — shell commands, paths, URLs

AGENT_COLORS=(
  $'\033[1;32m' # Bold Green
  $'\033[1;33m' # Bold Yellow
  $'\033[1;34m' # Bold Blue
  $'\033[1;35m' # Bold Magenta
  $'\033[1;36m' # Bold Cyan
  $'\033[1;37m' # Bold White
  $'\033[1;31m' # Bold Red
)

# ── State Management (Bash 3.2 compatible) ──

set_state() {
  local agent_san="$1" key="$2"; shift 2
  eval "STATE_${agent_san}_${key}=\"\$*\""
}

get_state() {
  local agent_san="$1" key="$2"
  eval "echo \"\$STATE_${agent_san}_${key}\""
}

# ── Helpers ──

cache_run_model() {
  local agent_san="$1" msg="$2" rid prov mdl
  rid=$(echo "$msg" | grep -oE 'runId=[a-f0-9-]+' | head -1 | cut -d= -f2)
  prov=$(echo "$msg" | grep -oE 'provider=[^ ]+' | head -1 | cut -d= -f2)
  mdl=$(echo "$msg" | grep -oE 'model=[^ ]+' | head -1 | cut -d= -f2)
  if [[ -n "$rid" && -n "$prov" ]]; then
    local cache_file; cache_file=$(get_state "$agent_san" "RUN_CACHE")
    echo "${rid}|${prov}|${mdl}" >> "$cache_file"
  fi
}

print_run_cost() {
  local agent_san="$1" msg="$2" ts="$3" cur_prov="$4" cur_mdl="$5" rid sid prov mdl
  local sessions_dir; sessions_dir=$(get_state "$agent_san" "SESSIONS_DIR")
  rid=$(echo "$msg" | grep -oE 'runId=[a-f0-9-]+' | head -1 | cut -d= -f2)
  sid=$(echo "$msg" | grep -oE 'sessionId=[a-f0-9-]+' | head -1 | cut -d= -f2)
  [[ -z "$sid" ]] && return
  
  if [[ -n "$rid" ]]; then
    local cache_file; cache_file=$(get_state "$agent_san" "RUN_CACHE")
    local cl; cl=$(grep "^${rid}|" "$cache_file" 2>/dev/null | tail -1)
    [[ -n "$cl" ]] && prov=$(echo "$cl" | cut -d'|' -f2) && mdl=$(echo "$cl" | cut -d'|' -f3)
  fi
  [[ -z "$prov" ]] && prov="$cur_prov"
  [[ -z "$mdl" ]] && mdl="$cur_mdl"
  
  sleep 0.5
  local sf="$sessions_dir/${sid}.jsonl"
  [[ ! -f "$sf" ]] && return
  
  local lu; lu=$(while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    echo "$l" | jq -e . >/dev/null 2>&1 || continue
    local r; r=$(echo "$l" | jq -r '.message.role // empty' 2>/dev/null)
    if [[ "$r" == "assistant" ]]; then
      local u; u=$(echo "$l" | jq -c '.message.usage // empty' 2>/dev/null)
      [[ -n "$u" && "$u" != "null" ]] && echo "$u"
    fi
  done < "$sf" | tail -1)
  
  [[ -z "$lu" || "$lu" == "null" ]] && return
  local cost inp outp cache_r cache_w total
  cost=$(echo "$lu" | jq -r '.cost.total // 0' 2>/dev/null)
  inp=$(echo "$lu" | jq -r '.input // 0' 2>/dev/null)
  outp=$(echo "$lu" | jq -r '.output // 0' 2>/dev/null)
  cache_r=$(echo "$lu" | jq -r '.cacheRead // 0' 2>/dev/null)
  cache_w=$(echo "$lu" | jq -r '.cacheWrite // 0' 2>/dev/null)
  
  local session_total
  if [[ -f "$sf" ]]; then
    session_total=$(while IFS= read -r l; do
      [[ -z "$l" ]] && continue
      echo "$l" | jq -e . >/dev/null 2>&1 || continue
      echo "$l" | jq -r '.message.usage.cost.total // 0' 2>/dev/null
    done < "$sf" | awk '{s+=$1} END {printf "%.4f", s}')
  fi
  [[ -z "$session_total" ]] && session_total="0.0000"
  
  local prefix; prefix=$(get_state "$agent_san" "PREFIX")
  local cache_detail=""
  [[ -n "$cache_w" && "$cache_w" != "0" ]] 2>/dev/null && cache_detail="  ${C_DIM}cache write: ${cache_w}${C_RST}"
  
  if [[ "$cache_r" -gt 0 ]] 2>/dev/null; then
    local inp_total=$((inp + cache_r))
    local cache_pct=0
    [[ $inp_total -gt 0 ]] && cache_pct=$((cache_r * 100 / inp_total))
    printf "%s %s ${C_YEL}💰 COST${C_RST}  \$%.4f  %s in + %s cached → %s out  ${C_DIM}%s%% cached${C_RST}  %s/%s  ${C_DIM}(session: \$%s)${C_RST}%s\n" \
      "$prefix" "$ts" "$cost" "$inp" "$cache_r" "$outp" "$cache_pct" "$prov" "$mdl" "$session_total" "$cache_detail"
  else
    printf "%s %s ${C_YEL}💰 COST${C_RST}  \$%.4f  %s tokens in → %s out  %s/%s  ${C_DIM}(session: \$%s)${C_RST}%s\n" \
      "$prefix" "$ts" "$cost" "$inp" "$outp" "$prov" "$mdl" "$session_total" "$cache_detail"
  fi
}

kv() { echo "$1" | grep -oE "$2=[^ ]+" | head -1 | cut -d= -f2; }
# Prefer structured payload from JSON line, fall back to key=value in msg
payload_key() {
  local line="$1" msg="$2" key="$3"
  local v; v=$(echo "$line" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null)
  [[ -n "$v" && "$v" != "null" ]] && { echo "$v"; return; }
  kv "$msg" "$key"
}
short() { echo "${1:0:8}"; }

fmtms() {
  local ms="$1"
  if [[ -z "$ms" || "$ms" == "null" ]]; then echo "?"; return; fi
  if (( ms >= 60000 )); then printf "%dm%ds" $((ms/60000)) $(((ms%60000)/1000))
  elif (( ms >= 1000 )); then printf "%d.%ds" $((ms/1000)) $(((ms%1000)/100))
  else printf "%dms" "$ms"; fi
}

fmtbytes() {
  local b="$1"
  if [[ -z "$b" || "$b" == "null" || "$b" == "0" ]]; then echo "0B"; return; fi
  if (( b >= 1048576 )); then printf "%d.%dMB" $((b/1048576)) $(((b%1048576)*10/1048576))
  elif (( b >= 1024 )); then printf "%dKB" $((b/1024))
  else printf "%dB" "$b"; fi
}

ts_to_secs() {
  local t="$1"
  local h=${t:0:2} m=${t:3:2} s=${t:6:2}
  echo $(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

tool_desc() {
  case "$1" in
    browser)        echo "interacting with web page" ;;
    web_fetch)      echo "fetching content from URL" ;;
    web_search)     echo "searching the web" ;;
    exec)           echo "running a shell command" ;;
    write)          echo "writing to a file" ;;
    read)           echo "reading a file" ;;
    edit)           echo "editing a file" ;;
    memory_search)  echo "searching agent memory" ;;
    sessions_list)  echo "listing chat sessions" ;;
    cron)           echo "managing a scheduled task" ;;
    image)          echo "processing an image" ;;
    message)        echo "sending a message" ;;
    *)              echo "$1" ;;
  esac
}

get_tool_args() {
  local agent_san="$1" toolname="$2"
  local sessions_dir; sessions_dir=$(get_state "$agent_san" "SESSIONS_DIR")
  local run_sid; run_sid=$(get_state "$agent_san" "RUN_SID")
  [[ -z "$run_sid" ]] && return
  local sf="$sessions_dir/${run_sid}.jsonl"
  [[ ! -f "$sf" ]] && return
  tail -15 "$sf" 2>/dev/null | while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    echo "$l" | jq -c '
      .message.content[]? |
      select(.type == "toolCall" and .name == "'"$toolname"'") |
      .arguments
    ' 2>/dev/null
  done | grep -v '^$\|^null$' | tail -1
}

get_last_result() {
  local agent_san="$1"
  local sessions_dir; sessions_dir=$(get_state "$agent_san" "SESSIONS_DIR")
  local run_sid; run_sid=$(get_state "$agent_san" "RUN_SID")
  [[ -z "$run_sid" ]] && return
  local sf="$sessions_dir/${run_sid}.jsonl"
  [[ ! -f "$sf" ]] && return
  tail -5 "$sf" 2>/dev/null | while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    echo "$l" | jq -r '
      select(.message.role == "toolResult") |
      .message.content[] |
      select(.type == "text") |
      .text
    ' 2>/dev/null
  done | grep -v '^$\|^null$' | tail -1
}

format_nexus_event() {
  local agent_san="$1" line="$2"
  local event ts dur domain status out
  local prefix; prefix=$(get_state "$agent_san" "PREFIX")

  event=$(echo "$line" | jq -r '.event // empty' 2>/dev/null)
  [[ -z "$event" ]] && return 1

  ts=$(date +%H:%M:%S)
  domain=$(echo "$line" | jq -r '.domain // empty' 2>/dev/null)
  status=$(echo "$line" | jq -r '.status // empty' 2>/dev/null)
  dur=$(echo "$line" | jq -r '.duration_ms // empty' 2>/dev/null)

  case "$event" in
    mcp_handshake)
      local proto_ver reason
      proto_ver=$(echo "$line" | jq -r '.protocol_version // empty' 2>/dev/null)
      if [[ "$status" == "error" ]]; then
        reason=$(echo "$line" | jq -r '.reason // "unknown"' 2>/dev/null)
        printf "%s %s ${C_CYN}🔌 MCP${C_RST}     Handshake with %s  ${C_RED}ERROR${C_RST}  %s  %s\n" \
          "$prefix" "$ts" "$domain" "$(fmtms "$dur")" "$reason"
      else
        printf "%s %s ${C_CYN}🔌 MCP${C_RST}     Handshake with %s  %s  ok  ${C_DIM}%s${C_RST}\n" \
          "$prefix" "$ts" "$domain" "$(fmtms "$dur")" "$proto_ver"
      fi
      ;;
    mcp_discover)
      local tool_count tools
      tool_count=$(echo "$line" | jq -r '.tool_count // 0' 2>/dev/null)
      tools=$(echo "$line" | jq -r '.tools // empty' 2>/dev/null)
      if [[ ${#tools} -gt 60 ]]; then tools="${tools:0:57}..."; fi
      printf "%s %s ${C_CYN}🔌 MCP${C_RST}     Discovery: %s tools (%s)  %s\n" \
        "$prefix" "$ts" "$tool_count" "$tools" "$(fmtms "$dur")"
      ;;
    mcp_tool_call)
      local tool product_count resp_bytes products_sample error_detail
      tool=$(echo "$line" | jq -r '.tool // "?"' 2>/dev/null)
      product_count=$(echo "$line" | jq -r '.product_count // 0' 2>/dev/null)
      resp_bytes=$(echo "$line" | jq -r '.response_bytes // 0' 2>/dev/null)
      products_sample=$(echo "$line" | jq -r '.products_sample // empty' 2>/dev/null)
      error_detail=$(echo "$line" | jq -r '.error_detail // empty' 2>/dev/null)
      if [[ "$status" == "error" ]]; then
        printf "%s %s ${C_CYN}🔌 MCP${C_RST}     %s → ${C_RED}ERROR${C_RST}  %s  %s\n" \
          "$prefix" "$ts" "$tool" "$(fmtms "$dur")" "$error_detail"
      else
        printf "%s %s ${C_CYN}🔌 MCP${C_RST}     %s → %s products  %s  %s\n" \
          "$prefix" "$ts" "$tool" "$product_count" "$(fmtms "$dur")" "$(fmtbytes "$resp_bytes")"
        if [[ -n "$products_sample" ]]; then
          printf "%s                   ${C_DIM}↳ %s${C_RST}\n" "$prefix" "$products_sample"
        fi
      fi
      ;;
    search_start)
      local query mode
      query=$(echo "$line" | jq -r '.query // empty' 2>/dev/null)
      mode=$(echo "$line" | jq -r '.mode // empty' 2>/dev/null)
      printf "%s %s ${C_BMAG}🛒 NEXUS${C_RST}   Search start: %s \"%s\" (%s)\n" \
        "$prefix" "$ts" "$domain" "$query" "$mode"
      ;;
    search_complete)
      local products endpoint relevance
      products=$(echo "$line" | jq -r '.products // 0' 2>/dev/null)
      endpoint=$(echo "$line" | jq -r '.endpoint // empty' 2>/dev/null)
      relevance=$(echo "$line" | jq -r '.relevance // empty' 2>/dev/null)
      local rel_info=""; [[ -n "$relevance" ]] && rel_info="  relevance=${relevance}"
      printf "%s %s ${C_BMAG}🛒 NEXUS${C_RST}   Search complete: %s products via %s%s\n" \
        "$prefix" "$ts" "$products" "$endpoint" "$rel_info"
      ;;
    error)
      local reason note
      reason=$(echo "$line" | jq -r '.reason // empty' 2>/dev/null)
      note=$(echo "$line" | jq -r '.note // empty' 2>/dev/null)
      printf "%s %s ${C_RED}🛒 NEXUS${C_RST}   ERROR: %s  %s\n" "$prefix" "$ts" "${reason:-$note}" "$domain"
      ;;
    *)
      local note; note=$(echo "$line" | jq -r '.note // .reason // .status // empty' 2>/dev/null)
      [[ -n "$event" ]] && printf "%s %s ${C_BMAG}🛒 NEXUS${C_RST}   %s  ${C_DIM}%s${C_RST}\n" "$prefix" "$ts" "$event" "$note"
      ;;
  esac
}

# ── Channel summary (Telegram bot, allowlists, other channels) ──
print_agent_channel_summary() {
  local agent_dir="$1" agent_name="$2" port="$3"
  local config="$agent_dir/config/openclaw.json"
  [[ ! -f "$config" ]] && return
  local channels_json
  channels_json=$(jq -c '.channels // {} | to_entries[] | select(.value.enabled == true) | {key: .key, allowFrom: (.value.allowFrom // [])}' "$config" 2>/dev/null)
  [[ -z "$channels_json" ]] && return
  local first=1
  while IFS= read -r ch; do
    [[ -z "$ch" ]] && continue
    local ch_name allow_from
    ch_name=$(echo "$ch" | jq -r '.key')
    allow_from=$(echo "$ch" | jq -r '.allowFrom | if type == "array" then join(", ") else tostring end' 2>/dev/null)
    [[ "$allow_from" == "null" || "$allow_from" == "" ]] && allow_from="(none)"
    local line_prefix=""
    [[ $first -eq 1 ]] && line_prefix="${C_GRN}$agent_name${C_RST} (port $port):  " && first=0
    if [[ "$ch_name" == "telegram" ]]; then
      local bot_username=""
      if [[ -f "$agent_dir/.env" ]]; then
        local token
        token=$(set -a; source "$agent_dir/.env" 2>/dev/null; set +a; echo "${TELEGRAM_BOT_TOKEN:-}")
        if [[ -n "$token" ]]; then
          bot_username=$(curl -s --max-time 3 "https://api.telegram.org/bot${token}/getMe" 2>/dev/null | jq -r '.result.username // empty' 2>/dev/null)
          [[ -n "$bot_username" ]] && bot_username="@$bot_username"
        fi
      fi
      [[ -z "$bot_username" ]] && bot_username="${C_DIM}(token not resolved)${C_RST}"
      printf "%s${C_CYN}telegram${C_RST}: %s  allowlist: %s\n" "$line_prefix" "$bot_username" "$allow_from"
    else
      printf "%s${C_CYN}%s${C_RST}: allowlist: %s\n" "$line_prefix" "$ch_name" "$allow_from"
    fi
  done <<< "$channels_json"
}

# ── Initialization ──

FAIL_PAT='API key|api key|apiKey|missing.*key|unauthorized|401|403|authentication|auth failed|invalid.*token|tool.*fail|action.*fail|tool error|action error|skill.*fail|not configured|not available|missing config|ECONNREFUSED|ETIMEDOUT|ENOTFOUND|timed? ?out\b|connection refused|network error|fetch failed|openai.*error|ollama.*error|rate limit|429|model.*unavailable|\berror\b|Error[: ]|exception|failed|Failure'
LIFECYCLE_PAT='lane enqueue|lane dequeue|embedded run start|embedded run done|embedded run prompt start|embedded run prompt end|embedded run agent start|embedded run agent end|embedded run tool start|embedded run tool end|embedded run compaction|session state:|run registered|run cleared|lane task (done|error)|config change|config reload|browser|telegram sendMessage|starting provider|health-monitor|Native image:|Media:.*image|media understanding'

# Parse arguments
TARGET="$1"
if [[ -z "$TARGET" || "$TARGET" == "--all" ]]; then
  MODE="all"
  AGENT_LIST=$(list_agent_dirs)
else
  MODE="single"
  AGENT_LIST="$TARGET"
fi

FILES_TO_TAIL=()
AGENT_SANS=()

i=0
for ag in $AGENT_LIST; do
  dir="agents/$ag"
  [[ -d "$dir" && -f "$dir/agent.conf" ]] || continue
  
  info=$( (source "$dir/agent.conf"; echo "$AGENT_NAME|$AGENT_PORT") )
  name=$(echo "$info" | cut -d'|' -f1)
  san=$(echo "$ag" | tr '-' '_')
  
  log_dir="$dir/logs"
  # Use the most recently modified log so we follow where the container is actually writing
  # (container may be UTC while host is not, so openclaw-YYYY-MM-DD can differ)
  latest=$(ls -t "$log_dir"/openclaw-*.log 2>/dev/null | head -1)
  nexus_log="$log_dir/nexus-search.log"
  media_vision_log="$log_dir/media-vision.log"
  touch "$nexus_log" "$media_vision_log" 2>/dev/null || true
  
  sessions_dir="$dir/config-runtime/agents/main/sessions"
  [[ ! -d "$sessions_dir" ]] && sessions_dir="$dir/config/agents/main/sessions"
  [[ ! -d "$sessions_dir" ]] && sessions_dir="$dir/logs/sessions"
  
  run_cache=$(mktemp -t "openclaw-${san}.XXXXXX")
  
  color_idx=$(( i % ${#AGENT_COLORS[@]} ))
  color="${AGENT_COLORS[$color_idx]}"
  
  if [[ "$MODE" == "all" ]]; then
    padded_name=$(printf "%-12s" "${name:0:12}")
    prefix="${color}[${padded_name}]${C_RST}"
  else
    prefix=""
  fi
  
  set_state "$san" "NAME" "$name"
  set_state "$san" "PORT" "$(echo "$info" | cut -d'|' -f2)"
  set_state "$san" "PREFIX" "$prefix"
  set_state "$san" "SESSIONS_DIR" "$sessions_dir"
  set_state "$san" "RUN_CACHE" "$run_cache"
  set_state "$san" "ROUND_NUM" "0"
  set_state "$san" "TOOL_COUNT" "0"
  set_state "$san" "SENT_COUNT" "0"

  if [[ -n "$latest" && -f "$latest" ]]; then
    _last_start=$(grep -o 'embedded run start:.*' "$latest" 2>/dev/null | tail -1)
    set_state "$san" "RUN_PROVIDER" "$(echo "$_last_start" | grep -oE 'provider=[^ ]+' | head -1 | cut -d= -f2)"
    set_state "$san" "RUN_MODEL" "$(echo "$_last_start" | grep -oE 'model=[^ ]+' | head -1 | cut -d= -f2)"
    FILES_TO_TAIL+=("$latest")
  fi
  FILES_TO_TAIL+=("$nexus_log")
  FILES_TO_TAIL+=("$media_vision_log")
  
  AGENT_SANS+=("$san")
  i=$((i+1))
done

if [[ ${#FILES_TO_TAIL[@]} -eq 0 ]]; then
  echo "No logs found for target: $TARGET" >&2
  exit 1
fi

trap 'for san in "${AGENT_SANS[@]}"; do rm -f "$(get_state "$san" "RUN_CACHE")"; done' EXIT

COLS=${COLUMNS:-$(tput cols 2>/dev/null || echo 100)}
[[ "$MODE" == "all" ]] && BANNER_EXTRA="(ALL AGENTS)" || BANNER_EXTRA="($TARGET)"

cat << BANNER
──── OpenClaw Log Monitor $BANNER_EXTRA ────────────────────
 Watching: requests, LLM calls, tool use, token costs, errors
 Also:     Shopify Nexus MCP calls (nexus-search.log), image vision (media-vision.log)
 Tip:      Run lifecycle needs OPENCLAW_LOG_LEVEL=debug (set in docker-compose; restart agent)
 Photos:   Vision CLI logs to media-vision.log — watch-logs shows 📎 Media when Ollama describes the image
 Errors:   "Ollama timeout" = no local Ollama / network; "exec host=node" = exec wants host (see CLAUDE.md)
BANNER
if [[ "$MODE" == "all" ]]; then
  echo " Agents:  $AGENT_LIST"
else
  echo " Logs:    ${FILES_TO_TAIL[*]}"
fi
for ag in $AGENT_LIST; do
  san=$(echo "$ag" | tr '-' '_')
  port=$(get_state "$san" "PORT")
  print_agent_channel_summary "agents/$ag" "$ag" "$port"
done
echo "────────────────────────────────────────────────────────────"

# Show recent activity from log; dedupe identical lines; collapse Telegram replies to one summary
for f in "${FILES_TO_TAIL[@]}"; do
  [[ "$f" == *"nexus-search.log" ]] && continue
  [[ "$f" == *"media-vision.log" ]] && continue
  [[ ! -f "$f" ]] && continue
  recent_count=0
  prev_msg="" prev_ts="" repeat_n=0
  sent_in_window=0
  while IFS= read -r line; do
    [[ "$line" != "{"* ]] && continue
    msg=$(echo "$line" | jq -r '(.["msg"] // .["message"] // .["1"] // .["2"] // (.["0"] | if type == "string" then . else tostring end)) // empty' 2>/dev/null) || true
    [[ -z "$msg" || "$msg" == "null" ]] && continue
    echo "$msg" | grep -qE "$FAIL_PAT|$LIFECYCLE_PAT" || continue
    [[ "$msg" == "web gateway heartbeat" ]] && continue
    if echo "$msg" | grep -qE 'session state:|^run registered:|^run cleared:|^lane dequeue:'; then continue; fi
    ts=$(echo "$line" | jq -r '.time // ""' 2>/dev/null) || ts=""
    [[ -n "$ts" ]] && ts="${ts:11:8}" || ts=$(date +%H:%M:%S)
    if echo "$msg" | grep -qE 'telegram sendMessage ok'; then
      sent_in_window=$((sent_in_window + 1))
      continue
    fi
    if [[ "$msg" == "$prev_msg" ]]; then
      repeat_n=$((repeat_n + 1))
      continue
    fi
    if [[ -n "$prev_msg" ]]; then
      if echo "$prev_msg" | grep -qE "$FAIL_PAT"; then
        dup_suffix=""; [[ $repeat_n -gt 1 ]] && dup_suffix=" ${C_DIM}(×${repeat_n})${C_RST}"
        printf "${C_DIM}[recent] %s${C_RST} ${C_RED}%s${C_RST}%s\n" "$prev_ts" "$prev_msg" "$dup_suffix"
      elif echo "$prev_msg" | grep -qE 'config change (detected|applied)'; then
        short=$(echo "$prev_msg" | sed 's/^config change detected; evaluating reload //; s/^config change applied (dynamic reads: //; s/^(//; s/)$//')
        printf "${C_DIM}[recent] %s${C_RST} ${C_CYN}CONFIG${C_RST} %s\n" "$prev_ts" "${short:-$prev_msg}"
      else
        [[ ${#prev_msg} -gt 200 ]] && prev_msg="${prev_msg:0:197}..."
        printf "${C_DIM}[recent] %s${C_RST} %s\n" "$prev_ts" "$prev_msg"
      fi
      recent_count=$((recent_count + 1))
    fi
    prev_msg="$msg"; prev_ts="$ts"; repeat_n=1
  done < <(tail -80 "$f" 2>/dev/null)
  if [[ -n "$prev_msg" ]]; then
    if echo "$prev_msg" | grep -qE "$FAIL_PAT"; then
      dup_suffix=""; [[ $repeat_n -gt 1 ]] && dup_suffix=" ${C_DIM}(×${repeat_n})${C_RST}"
      printf "${C_DIM}[recent] %s${C_RST} ${C_RED}%s${C_RST}%s\n" "$prev_ts" "$prev_msg" "$dup_suffix"
    elif echo "$prev_msg" | grep -qE 'config change (detected|applied)'; then
      short=$(echo "$prev_msg" | sed 's/^config change detected; evaluating reload //; s/^config change applied (dynamic reads: //; s/^(//; s/)$//')
      printf "${C_DIM}[recent] %s${C_RST} ${C_CYN}CONFIG${C_RST} %s\n" "$prev_ts" "${short:-$prev_msg}"
    else
      [[ ${#prev_msg} -gt 200 ]] && prev_msg="${prev_msg:0:197}..."
      printf "${C_DIM}[recent] %s${C_RST} %s\n" "$prev_ts" "$prev_msg"
    fi
    recent_count=$((recent_count + 1))
  fi
  if [[ $sent_in_window -gt 0 ]]; then
    [[ $sent_in_window -eq 1 ]] && rword="reply" || rword="replies"
    printf "${C_DIM}[recent]${C_RST} ${C_CYN}… %s Telegram %s in this window${C_RST}\n" "$sent_in_window" "$rword"
  fi
  if [[ $recent_count -eq 0 ]]; then
    has_run=$(grep -c 'embedded run' "$f" 2>/dev/null | tr -d ' ') || has_run=0
    if [[ "${has_run:-0}" -eq 0 ]]; then
      agent_from_path=$(echo "$f" | sed -n 's|.*/agents/\([^/]*\)/logs/.*|\1|p')
      echo "${C_RED}No run lifecycle in log. Set logging.level to \"debug\" in agents/${agent_from_path:-$TARGET}/config/openclaw.json and restart: ./scripts/compose-up.sh ${agent_from_path:-$TARGET} -d${C_RST}"
    fi
  fi
done
echo "──────────────────────────────────────────────────────────── (live)"

curr_san=""
curr_prefix=""

tail -f "${FILES_TO_TAIL[@]}" 2>/dev/null | while read -r line; do
  if [[ "$line" == "==> "* ]]; then
    file_path=$(echo "$line" | sed 's/==> \(.*\) <==/\1/')
    for ag in $AGENT_LIST; do
      if [[ "$file_path" == *"agents/$ag/"* ]]; then
        curr_san=$(echo "$ag" | tr '-' '_')
        curr_prefix=$(get_state "$curr_san" "PREFIX")
        if [[ "$file_path" == *"nexus-search.log" ]]; then
          curr_file_type="nexus"
        elif [[ "$file_path" == *"media-vision.log" ]]; then
          curr_file_type="media_vision"
        else
          curr_file_type="app"
        fi
        break
      fi
    done
    continue
  fi
  [[ -z "$line" ]] && continue
  [[ -z "$curr_san" ]] && continue

  if [[ "$curr_file_type" == "nexus" ]]; then
    if echo "$line" | jq -e '.event' >/dev/null 2>&1; then
      format_nexus_event "$curr_san" "$line"
    fi
    continue
  fi

  if [[ "$curr_file_type" == "media_vision" ]]; then
    # Tab-separated: timestamp	status	host:port	path
    if [[ "$line" == *$'\t'ok$'\t'* ]]; then
      ts_media=$(echo "$line" | cut -f1)
      host_part=$(echo "$line" | cut -f3)
      [[ -n "$ts_media" ]] && ts_media="${ts_media:11:8}" || ts_media=$(date +%H:%M:%S)
      printf "%s %s ${C_CYN}📎 Media${C_RST}  image described via Ollama (vision)  ${C_DIM}%s${C_RST}\n" \
        "$curr_prefix" "$ts_media" "${host_part:-Ollama}"
    elif [[ "$line" == *$'\t'unavailable$'\t'* ]]; then
      ts_media=$(echo "$line" | cut -f1)
      [[ -n "$ts_media" ]] && ts_media="${ts_media:11:8}" || ts_media=$(date +%H:%M:%S)
      printf "%s %s ${C_YEL}📎 Media${C_RST}  vision unavailable (no Ollama)  ${C_DIM}check OLLAMA_HOST / LAN${C_RST}\n" \
        "$curr_prefix" "$ts_media"
    fi
    continue
  fi

  # OpenClaw log format: support both Pino-style (msg/message) and legacy numeric keys (1/2/0) for compatibility across upgrades.
  [[ "$line" != "{"* ]] && continue
  msg=$(echo "$line" | jq -r '
    (.["msg"]     | if type == "string" and length > 0 then . else empty end) //
    (.["message"] | if type == "string" and length > 0 then . else empty end) //
    (.["1"]       | if type == "string" and length > 0 then . else empty end) //
    (.["2"]       | if type == "string" and length > 0 then . else empty end) //
    (.["0"]       | if type == "string" then . else tostring end)
  ' 2>/dev/null) || msg=""
  [[ -z "$msg" || "$msg" == "null" ]] && continue
  echo "$msg" | grep -qE "$FAIL_PAT|$LIFECYCLE_PAT" || continue

  ts=$(date +%H:%M:%S)
  out=""
  
  if echo "$msg" | grep -qE 'session state:|^run registered:|^run cleared:|^lane dequeue:'; then continue; fi
  [[ "$msg" == "web gateway heartbeat" ]] && continue

  round_num=$(get_state "$curr_san" "ROUND_NUM")
  tool_count=$(get_state "$curr_san" "TOOL_COUNT")
  run_model=$(get_state "$curr_san" "RUN_MODEL")
  run_provider=$(get_state "$curr_san" "RUN_PROVIDER")
  llm_start_secs=$(get_state "$curr_san" "LLM_START_SECS")
  tool_start_secs=$(get_state "$curr_san" "TOOL_START_SECS")

  if echo "$msg" | grep -qE '^lane enqueue:'; then
    lane=$(payload_key "$line" "$msg" lane)
    echo "$lane" | grep -q '^session:' && continue
    q=$(payload_key "$line" "$msg" queueSize)
    out="${C_CYN}📥 QUEUE${C_RST}  New request queued  ${C_DIM}(${q} in queue)${C_RST}"

  elif echo "$msg" | grep -qE '^embedded run start:'; then
    cache_run_model "$curr_san" "$msg"
    run_provider=$(payload_key "$line" "$msg" provider)
    run_model=$(payload_key "$line" "$msg" model)
    chan=$(payload_key "$line" "$msg" messageChannel)
    think=$(payload_key "$line" "$msg" thinking)
    run_sid=$(payload_key "$line" "$msg" sessionId)
    set_state "$curr_san" "RUN_PROVIDER" "$run_provider"
    set_state "$curr_san" "RUN_MODEL" "$run_model"
    set_state "$curr_san" "RUN_SID" "$run_sid"
    set_state "$curr_san" "ROUND_NUM" "0"
    set_state "$curr_san" "TOOL_COUNT" "0"
    set_state "$curr_san" "TOOL_START_SECS" "0"
    set_state "$curr_san" "TOOL_LAST_ERROR" ""
    sid=$(short "$run_sid")
    run_id_short=$(short "$(payload_key "$line" "$msg" runId)")
    tinfo=""
    [[ "$think" == "on" ]] && tinfo=" ${C_MAG}+thinking${C_RST}"
    out="${C_GRN}▶ RUN${C_RST}    ${chan} request → ${run_provider}/${run_model}${tinfo}  ${C_DIM}session:${sid} run:${run_id_short}${C_RST}"

  elif echo "$msg" | grep -qE '^embedded run prompt start:'; then
    round_num=$((round_num + 1))
    set_state "$curr_san" "ROUND_NUM" "$round_num"
    set_state "$curr_san" "TOOL_COUNT" "0"
    out="${C_MAG}  PROMPT${C_RST}  Building prompt for LLM ${C_DIM}(round ${round_num})${C_RST}"

  elif echo "$msg" | grep -qE '^embedded run agent start:'; then
    llm_start_secs=$(date +%s)
    set_state "$curr_san" "LLM_START_SECS" "$llm_start_secs"
    out="${C_MAG}  LLM ▶${C_RST}  Sending prompt to ${run_provider:-LLM}/${run_model:-...}..."

  elif echo "$msg" | grep -qE '^embedded run agent end:'; then
    llm_elapsed=""
    if [[ $llm_start_secs -gt 0 ]]; then
      llm_end_secs=$(date +%s)
      llm_delta=$((llm_end_secs - llm_start_secs))
      [[ $llm_delta -lt 0 ]] && llm_delta=0
      llm_elapsed=" in ${llm_delta}s"
    fi
    out="${C_MAG}  LLM ◀${C_RST}  Model responded${llm_elapsed}  ${C_DIM}(processing reply...)${C_RST}"

  elif echo "$msg" | grep -qE '^embedded run tool start:'; then
    tool=$(payload_key "$line" "$msg" tool)
    tool_count=$((tool_count + 1))
    set_state "$curr_san" "TOOL_COUNT" "$tool_count"
    desc=$(tool_desc "$tool")
    tool_start_secs=$(date +%s)
    set_state "$curr_san" "TOOL_START_SECS" "$tool_start_secs"
    tcid=$(payload_key "$line" "$msg" toolCallId)
    [[ -n "$tcid" ]] && tcid=" ${C_DIM}${tcid}${C_RST}" || tcid=""
    printf "%s %s ${C_YEL}  TOOL▶${C_RST}  #${tool_count} ${tool} — ${desc}%s\n" "$curr_prefix" "$ts" "$tcid"
    args_raw=$(get_tool_args "$curr_san" "$tool")
    if [[ "$MODE" == "all" ]]; then maxw=$((COLS - 38)); else maxw=$((COLS - 22)); fi
    if [[ -n "$args_raw" ]]; then
      case "$tool" in
        exec)
          cmd=$(echo "$args_raw" | jq -r '.command // empty' 2>/dev/null)
          if [[ -n "$cmd" && "$cmd" != "null" ]]; then
            printf "%s               ${C_CMD}\$ %s${C_RST}\n" "$curr_prefix" "${cmd:0:$maxw}"
            [[ ${#cmd} -gt $maxw ]] && printf "%s               ${C_DIM}... (truncated)${C_RST}\n" "$curr_prefix"
          fi
          ;;
        web_fetch)
          url=$(echo "$args_raw" | jq -r '.url // empty' 2>/dev/null)
          [[ -n "$url" && "$url" != "null" ]] && printf "%s               ${C_CMD}→ %s${C_RST}\n" "$curr_prefix" "${url:0:$maxw}"
          ;;
        web_search)
          q=$(echo "$args_raw" | jq -r '.query // empty' 2>/dev/null)
          [[ -n "$q" && "$q" != "null" ]] && printf "%s               ${C_CMD}? \"%s\"${C_RST}\n" "$curr_prefix" "${q:0:$maxw}"
          ;;
        read|write|edit)
          path=$(echo "$args_raw" | jq -r '.file_path // .path // empty' 2>/dev/null)
          [[ -n "$path" && "$path" != "null" ]] && printf "%s               ${C_CMD}→ %s${C_RST}\n" "$curr_prefix" "${path:0:$maxw}"
          ;;
        memory_search)
          q=$(echo "$args_raw" | jq -r '.query // .q // empty' 2>/dev/null)
          [[ -n "$q" && "$q" != "null" ]] && printf "%s               ${C_CMD}? \"%s\"${C_RST}\n" "$curr_prefix" "${q:0:$maxw}"
          ;;
        cron)
          name=$(echo "$args_raw" | jq -r '.name // .action // empty' 2>/dev/null)
          sched=$(echo "$args_raw" | jq -r '.schedule // .cron // empty' 2>/dev/null)
          if [[ -n "$name" && "$name" != "null" ]]; then
            printf "%s               ${C_CMD}%s${C_RST}\n" "$curr_prefix" "${name:0:$maxw}"
          fi
          if [[ -n "$sched" && "$sched" != "null" ]]; then
            printf "%s               ${C_DIM}schedule: %s${C_RST}\n" "$curr_prefix" "${sched:0:$((maxw-12))}"
          fi
          ;;
        image)
          prompt=$(echo "$args_raw" | jq -r '.prompt // .url // empty' 2>/dev/null)
          [[ -n "$prompt" && "$prompt" != "null" ]] && printf "%s               ${C_CMD}→ %s${C_RST}\n" "$curr_prefix" "${prompt:0:$maxw}"
          ;;
      esac
    else
      tool_call_id=$(payload_key "$line" "$msg" toolCallId)
      run_id=$(payload_key "$line" "$msg" runId)
      if [[ "$tool" == "exec" ]]; then
        printf "%s               ${C_DIM}(exec command not in log — session is SQLite; runId=%s)${C_RST}\n" "$curr_prefix" "${run_id:-—}"
      elif [[ -n "$tool_call_id" || -n "$run_id" ]]; then
        printf "%s               ${C_DIM}runId=%s toolCallId=%s${C_RST}\n" "$curr_prefix" "${run_id:-—}" "${tool_call_id:-—}"
      fi
    fi
    continue

  elif echo "$msg" | grep -qE '^embedded run tool end:'; then
    tool=$(payload_key "$line" "$msg" tool)
    tcid=$(payload_key "$line" "$msg" toolCallId)
    tcid_suffix=""; [[ -n "$tcid" ]] && tcid_suffix=" ${C_DIM}${tcid}${C_RST}"
    tool_elapsed=""
    tool_delta=0
    if [[ $tool_start_secs -gt 0 ]]; then
      tool_end_secs=$(date +%s)
      tool_delta=$((tool_end_secs - tool_start_secs))
      [[ $tool_delta -lt 0 ]] && tool_delta=0
      tool_elapsed="  ${C_DIM}${tool_delta}s${C_RST}"
    fi
    if [[ "$tool" == "web_search" || "$tool" == "web_fetch" ]]; then
      tool_error=$(get_state "$curr_san" "TOOL_LAST_ERROR")
      if [[ -n "$tool_error" ]]; then
        printf "%s %s ${C_YEL}  TOOL◀${C_RST}  ${tool} ${C_RED}✗ FAILED${C_RST}  %s${tool_elapsed}%s\n" \
          "$curr_prefix" "$ts" "$tool_error" "$tcid_suffix"
        set_state "$curr_san" "TOOL_LAST_ERROR" ""
      else
        if [[ "$MODE" == "all" ]]; then maxw=$((COLS - 48)); else maxw=$((COLS - 32)); fi
        printf "%s %s ${C_YEL}  TOOL◀${C_RST}  ${tool} ${C_GRN}✓ OK${C_RST}${tool_elapsed}%s\n" \
          "$curr_prefix" "$ts" "$tcid_suffix"
      fi
    else
      printf "%s %s ${C_YEL}  TOOL◀${C_RST}  ${tool} done${tool_elapsed}%s\n" "$curr_prefix" "$ts" "$tcid_suffix"
      if [[ "$tool" == "exec" ]]; then
        result=$(get_last_result "$curr_san")
        if [[ -n "$result" ]]; then
          first=$(echo "$result" | head -1)
          if [[ "$MODE" == "all" ]]; then maxw=$((COLS - 38)); else maxw=$((COLS - 22)); fi
          [[ ${#first} -gt $maxw ]] && first="${first:0:$((maxw - 3))}..."
          printf "%s               ${C_DIM}↳ %s${C_RST}\n" "$curr_prefix" "$first"
        fi
      fi
    fi
    set_state "$curr_san" "TOOL_START_SECS" "0"
    continue

  elif echo "$msg" | grep -qE '^embedded run done:'; then
    dur=$(payload_key "$line" "$msg" durationMs)
    abt=$(payload_key "$line" "$msg" aborted)
    sid=$(short "$(payload_key "$line" "$msg" sessionId)")
    rid=$(short "$(payload_key "$line" "$msg" runId)")
    reason=$(payload_key "$line" "$msg" reason)
    if [[ "$abt" == "true" ]]; then
      reason_suffix=""
      [[ -n "$reason" ]] && reason_suffix="  ${C_DIM}reason: ${reason:0:50}${C_RST}"
      out="${C_RED}✗ ABORT${C_RST}  Request aborted after $(fmtms "$dur")  ${C_DIM}session:${sid} run:${rid}${C_RST}${reason_suffix}"
    else
      out="${C_GRN}✔ DONE${C_RST}   Request complete  $(fmtms "$dur") total  ${C_DIM}session:${sid} run:${rid}${C_RST}"
    fi
    printf "%s %s ${out}\n" "$curr_prefix" "$ts"
    print_run_cost "$curr_san" "$msg" "$ts" "$run_provider" "$run_model"
    set_state "$curr_san" "ROUND_NUM" "0"
    set_state "$curr_san" "TOOL_COUNT" "0"
    continue

  elif echo "$msg" | grep -qE '^\[tools\] (web_search|web_fetch) failed:'; then
    # Intercept tool failures — store for display with tool end, suppress standalone print
    err_full=$(echo "$msg" | sed 's/^\[tools\] [^ ]* failed: //')
    http_code=$(echo "$err_full" | grep -oE '\([0-9]{3}\)' | head -1 | tr -d '()')
    detail=$(echo "$err_full" | grep -oE '"detail":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [[ -n "$http_code" && -n "$detail" ]]; then
      err_short="${http_code}: ${detail:0:60}"
    elif [[ -n "$http_code" ]]; then
      err_short="${http_code}: $(echo "$err_full" | head -c 60)"
    else
      err_short="${err_full:0:70}"
    fi
    set_state "$curr_san" "TOOL_LAST_ERROR" "$err_short"
    continue

  elif echo "$msg" | grep -qE '^Media:.*image'; then
    out="${C_CYN}📎 Media${C_RST}  image described (vision) before prompt  ${C_DIM}(see Ollama server for POST /api/chat)${C_RST}"
  elif echo "$msg" | grep -qE '^Native image:'; then
    out="${C_YEL}📷 Native image${C_RST} sent to model  ${C_DIM}(no media understanding; image in prompt)${C_RST}"
  elif echo "$msg" | grep -qE 'config change|config.*reload applied'; then
    short=$(echo "$msg" | sed 's/^config change detected; evaluating reload //; s/^config change applied (dynamic reads: //; s/^(//; s/)$//')
    out="${C_CYN}  CONFIG${C_RST} ${short:-$msg}"
  elif echo "$msg" | grep -qE 'telegram sendMessage ok'; then
    sent_count=$(get_state "$curr_san" "SENT_COUNT")
    sent_count=$((sent_count + 1))
    set_state "$curr_san" "SENT_COUNT" "$sent_count"
    mid=$(payload_key "$line" "$msg" message)
    if [[ $sent_count -eq 1 ]]; then
      [[ -n "$mid" ]] && out="${C_CYN}📤 Reply delivered${C_RST}  to user (msg #${mid})" || out="${C_CYN}📤 Reply delivered${C_RST}  to user"
      set_state "$curr_san" "JUST_PRINTED_SENT" "1"
    else
      out=""
      continue
    fi
  elif echo "$msg" | grep -qE 'starting provider.*@'; then
    out="${C_CYN}  CHANNEL${C_RST} Telegram provider started"
  elif echo "$msg" | grep -qE 'health-monitor: restarting'; then
    out="${C_CYN}  CHANNEL${C_RST} Reconnecting (stale socket)"
  elif echo "$msg" | grep -qiE 'browser'; then
    bmsg=$(echo "$msg" | sed 's/^[^ ]* //')
    out="${C_MAG}  BROWSR${C_RST} $bmsg"
  fi

  if [[ -z "$out" ]]; then
    if echo "$msg" | grep -qiE "$FAIL_PAT"; then
      tag="⚠ ERR   "; color="$C_RED"
      [[ "$msg" =~ "rate limit|429" ]] && tag="⚠ RATE  " && color="$C_YEL"
      out="${color}${tag}${C_RST} $msg"
    else
      continue
    fi
  fi
  # Flush batched SENT (extras after the first) before this line
  sent_count=$(get_state "$curr_san" "SENT_COUNT")
  if [[ "$sent_count" -gt 1 ]]; then
    printf "%s %s ${C_CYN}📤 Reply delivered${C_RST}  ×%s more\n" "$curr_prefix" "$ts" "$((sent_count - 1))"
  fi
  if [[ "$(get_state "$curr_san" "JUST_PRINTED_SENT")" == "1" ]]; then
    set_state "$curr_san" "SENT_COUNT" "1"
    set_state "$curr_san" "JUST_PRINTED_SENT" "0"
  else
    set_state "$curr_san" "SENT_COUNT" "0"
  fi
  printf "%s %s ${out}\n" "$curr_prefix" "$ts"
done
