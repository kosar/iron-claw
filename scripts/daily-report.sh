#!/usr/bin/env bash
# daily-report.sh — Daily operational report for an ironclaw agent.
# Usage: ./scripts/daily-report.sh <agent-name> [--date YYYY-MM-DD] [--save] [--all]
#
# --date  : report date (default: yesterday)
# --save  : write to agents/{name}/logs/reports/YYYY-MM-DD.txt + metrics.jsonl
# --all   : run for every agent (ignores positional <agent-name>)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ── Argument parsing ───────────────────────────────────────────────────────────
SAVE=false
ALL_AGENTS=false
REPORT_DATE=""
AGENT_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --date) REPORT_DATE="$2"; shift 2 ;;
    --save) SAVE=true; shift ;;
    --all)  ALL_AGENTS=true; shift ;;
    --*)    echo "Unknown option: $1" >&2; exit 1 ;;
    *)      [[ -z "$AGENT_ARG" ]] && AGENT_ARG="$1"; shift ;;
  esac
done

if [[ -z "$REPORT_DATE" ]]; then
  REPORT_DATE=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d yesterday +%Y-%m-%d)
fi

if [[ "$ALL_AGENTS" == false && -z "$AGENT_ARG" ]]; then
  echo "Usage: $0 <agent-name> [--date YYYY-MM-DD] [--save] [--all]" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "jq required: brew install jq" >&2; exit 1; }

# ── Output buffer (temp file — file writes are safe across pipe subshells) ────
OUTBUF=""   # path set per generate_report call
out()     { printf '%s\n' "$*" >> "$OUTBUF"; }
outf()    { printf "$@" >> "$OUTBUF"; printf '\n' >> "$OUTBUF"; }
divider() { printf '─%.0s' $(seq 1 52) >> "$OUTBUF"; printf '\n' >> "$OUTBUF"; }
section() { printf '\n%s\n' "$1" >> "$OUTBUF"; divider; }

# ── Helpers ────────────────────────────────────────────────────────────────────
fmt_cost() { printf "\$%.4f" "${1:-0}" 2>/dev/null || echo "${1:-0}"; }

fmt_num() {
  printf "%d" "${1:-0}" 2>/dev/null | awk '{
    s=$1; r=""
    for (i=length(s); i>0; i--) {
      r = substr(s,i,1) r
      if ((length(s)-i+1)%3==0 && i>1) r = "," r
    }
    print r
  }'
}

# 24 space-separated counts → sparkline characters ▁▂▃▄▅▆▇█
sparkline() {
  local blocks="▁▂▃▄▅▆▇█" max=1 line="" idx v
  for v in "$@"; do [[ "$v" -gt "$max" ]] 2>/dev/null && max="$v"; done
  for v in "$@"; do
    if [[ "$v" -eq 0 ]] 2>/dev/null; then line+=" "
    else
      idx=$(( v * 7 / max )); [[ "$idx" -gt 7 ]] && idx=7
      line+="${blocks:$idx:1}"
    fi
  done
  echo "$line"
}

# delta_label today avg label → "↑ +23% vs 7d avg" (empty if avg is 0)
delta_label() {
  awk -v t="$1" -v a="$2" -v l="${3:-7d avg}" 'BEGIN {
    if (a==0) exit
    p=(t-a)/a*100
    s=(p>50||p<-50)?"⚠":(p>10?"↑":(p<-10?"↓":"→"))
    printf "  %s %+.0f%% vs %s", s, p, l
  }' 2>/dev/null
}

# Query openclaw JSON config (which allows trailing commas — JSON5-like)
# Usage: cfgq '.some.jq.path'
cfgq() {
  perl -0pe 's/,(\s*[}\]])/\1/g' "$CONFIG_FILE" 2>/dev/null \
    | jq -r "${1}" 2>/dev/null || echo "${2:-}"
}

# ── LLM fallback (only when primary parse yields suspicious results) ────────
llm_parse_fallback() {
  local sample="$1" field="$2" token
  token=$(grep "OPENCLAW_GATEWAY_TOKEN" "$AGENT_ENV" 2>/dev/null | head -1 | cut -d= -f2-)
  [[ -z "$token" ]] && return 1
  curl -s --max-time 10 -X POST "http://localhost:${AGENT_PORT}/v1/chat/completions" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg m "openai/gpt-5-nano" \
      --arg s "You are a log parser. Return only valid JSON." \
      --arg u "Extract ${field} from these log lines as a JSON array:\n${sample}" \
      '{"model":$m,"messages":[{"role":"system","content":$s},{"role":"user","content":$u}],"max_tokens":256}'
    )" 2>/dev/null | jq -r '.choices[0].message.content // empty' 2>/dev/null
}

# ── Main report generator ──────────────────────────────────────────────────────
generate_report() {
  local LOG_FILE="$AGENT_LOG_DIR/openclaw-${REPORT_DATE}.log"
  local SESSIONS_DIR="$AGENT_SESSIONS"
  CONFIG_FILE="$AGENT_CONFIG/openclaw.json"   # used by cfgq()
  local REPORT_DIR="$AGENT_LOG_DIR/reports"
  local METRICS_FILE="$REPORT_DIR/metrics.jsonl"

  local EVTFILE SCACHE
  EVTFILE=$(mktemp /tmp/dr-events-XXXXXX.jsonl)
  SCACHE=$(mktemp /tmp/dr-sess-XXXXXX.jsonl)
  OUTBUF=$(mktemp /tmp/dr-out-XXXXXX.txt)

  local REPORT_OUTFILE=""
  [[ "$SAVE" == true ]] && { mkdir -p "$REPORT_DIR"; REPORT_OUTFILE="$REPORT_DIR/${REPORT_DATE}.txt"; }

  # ── Header ──────────────────────────────────────────────────────────────────
  printf '═%.0s' $(seq 1 52) >> "$OUTBUF"; printf '\n' >> "$OUTBUF"
  out "  IRONCLAW DAILY REPORT  •  ${AGENT_NAME}  •  ${REPORT_DATE}"
  printf '═%.0s' $(seq 1 52) >> "$OUTBUF"; printf '\n' >> "$OUTBUF"
  out "Generated: $(date '+%Y-%m-%d %H:%M:%S')  |  Period: ${REPORT_DATE} (full day)"

  # ── No log → early exit ──────────────────────────────────────────────────────
  local LOG_LINE_COUNT=0
  if [[ ! -f "$LOG_FILE" ]]; then
    out ""; out "No activity recorded for ${REPORT_DATE} (log file not found)."
    out "Expected: $LOG_FILE"
    _flush "$REPORT_OUTFILE"; rm -f "$EVTFILE" "$SCACHE" "$OUTBUF"; return
  fi
  LOG_LINE_COUNT=$(wc -l < "$LOG_FILE" | tr -d ' ')

  # ── Single-pass jq over log → structured events file ────────────────────────
  # Produces small JSONL: {ts, t:"run"|"error"|"warn", msg}
  # Errors: try "0" first; skip empty/web-content noise lines
  jq -c '
    (."msg" // ."message" // ."1") as $m1 | ."0" as $m0 | .time as $ts | ._meta.logLevelName as $lvl |
    if ($m1|type)=="string" and ($m1|startswith("embedded run")) then
      {ts:$ts, t:"run", msg:$m1}
    elif $lvl=="ERROR" then
      # m0 is sometimes a JSON object {"subsystem":"..."} used as a logger context —
      # in that case the real message is in m1. Otherwise m0 is the error string.
      # Also take first line only (m0 can embed \n for multi-line context like "Gateway target:").
      (if ($m0|type)=="string" and ($m0|ltrimstr(" ")|startswith("{")) then null
       elif ($m0|type)=="string" and ($m0|length)>0 then ($m0|split("\n")[0])
       else null end) as $m0_clean |
      (if $m0_clean != null then $m0_clean
       elif ($m1|type)=="string" and ($m1|length)>0 then ($m1|split("\n")[0])
       else null end) as $emsg |
      # Skip web-content noise and empty subsystem-only lines
      if $emsg and ($emsg | test("<<<EXTERNAL|UNTRUSTED_CONTENT|Source: Web Fetch|Source: local|Gateway target:|^Config:|^at ") | not) then
        {ts:$ts, t:"error", msg:$emsg}
      else empty end
    elif $lvl=="WARN" then
      # Skip JSON object m0 (subsystem-only log, no real message in m1)
      (if ($m0|type)=="string" and ($m0|ltrimstr(" ")|startswith("{")) then null
       elif ($m0|type)=="string" and ($m0|length)>0 then ($m0|split("\n")[0])
       else null end) as $wmsg |
      if $wmsg then {ts:$ts, t:"warn", msg:$wmsg} else empty end
    else empty end
  ' "$LOG_FILE" 2>/dev/null > "$EVTFILE" || true

  # ── Session JSONL cache: cost AND tool calls ─────────────────────────────────
  # Pre-filter to sessions that mention the report date; take all assistant messages.
  # Emit cost record AND any tool calls from same message (both can coexist).
  local sf
  for sf in "$SESSIONS_DIR"/*.jsonl; do
    [[ -f "$sf" ]] || continue
    grep -ql "${REPORT_DATE}T" "$sf" 2>/dev/null || continue
    jq -c '
      select(.message.role == "assistant") |
      # Cost record (when usage present)
      if .message.usage != null then
        {t:"cost",
         inp: (.message.usage.input  // 0),
         out: (.message.usage.output // 0),
         cr:  (.message.usage.cacheRead  // 0),
         cw:  (.message.usage.cacheWrite // 0),
         cost:(.message.usage.cost.total // 0),
         prov:(.message.provider // "unknown"),
         model:(.message.model   // "unknown")}
      else empty end,
      # Tool calls (always, regardless of usage presence)
      (.message.content[]? | select(.type == "toolCall") |
       {t:"tool", name:.name, cmd:(.arguments.command // "")})
    ' "$sf" 2>/dev/null >> "$SCACHE" || true
  done

  # ── Activity: run counts, durations, hourly sparkline ───────────────────────
  local starts_msgs dones_msgs
  starts_msgs=$(jq -r 'select(.t=="run" and (.msg|startswith("embedded run start"))) | .msg' \
    "$EVTFILE" 2>/dev/null)
  dones_msgs=$(jq -r 'select(.t=="run" and (.msg|startswith("embedded run done"))) | .msg' \
    "$EVTFILE" 2>/dev/null)

  # Use awk 'END{print NR}' instead of grep -c (grep -c exits 1 on 0 matches,
  # which with "|| echo 0" would produce double output "0\n0")
  local total_done heartbeat_count user_runs uniq_sessions
  total_done=$(echo "$dones_msgs" | awk 'NF{c++} END{print c+0}')
  heartbeat_count=$(echo "$starts_msgs" | awk '/messageChannel=heartbeat/{c++} END{print c+0}')
  user_runs=$(( total_done - heartbeat_count ))
  [[ "$user_runs" -lt 0 ]] && user_runs=0
  uniq_sessions=$(echo "$starts_msgs" | grep -oE 'sessionId=[a-f0-9-]+' \
    | cut -d= -f2 | sort -u | awk 'END{print NR}')

  # Duration stats (avg, max, >30s count) from run-done messages
  local avg_dur_s max_dur_s max_dur_at over30
  local DUR_STATS
  DUR_STATS=$(jq -r 'select(.t=="run" and (.msg|startswith("embedded run done"))) | [.msg,.ts]|@tsv' \
    "$EVTFILE" 2>/dev/null \
    | awk -F'\t' '
      BEGIN{n=0;sum=0;max=0;max_ts="";o30=0}
      {
        ms=0
        if (match($1,/durationMs=[0-9]+/)) {
          s2=substr($1,RSTART,RLENGTH); split(s2,a,"="); ms=a[2]+0
        }
        s=ms/1000.0; sum+=s; n++
        if(s>max){max=s;max_ts=$2}
        if(s>30)o30++
      }
      END{printf "avg=%.1f\nmax=%.1f\nmax_ts=%s\nover30=%d\n",(n>0?sum/n:0),max,max_ts,o30}')
  avg_dur_s=$(echo "$DUR_STATS" | awk -F= '/^avg=/{print $2}'); avg_dur_s="${avg_dur_s:-0}"
  max_dur_s=$(echo "$DUR_STATS" | awk -F= '/^max=/{print $2}'); max_dur_s="${max_dur_s:-0}"
  max_dur_at=$(echo "$DUR_STATS" | awk -F= '/^max_ts=/{print $2}' \
    | grep -oE 'T[0-9][0-9]:[0-9][0-9]' | sed 's/T//')
  over30=$(echo "$DUR_STATS" | awk -F= '/^over30=/{print $2}'); over30="${over30:-0}"

  # Hourly run distribution for sparkline
  local HOURLY_RAW i
  HOURLY_RAW=$(jq -r 'select(.t=="run" and (.msg|startswith("embedded run done"))) | .ts' \
    "$EVTFILE" 2>/dev/null \
    | grep -oE 'T[0-9][0-9]:' | sed 's/T//;s/://' | sort | uniq -c)
  local HOURLY=()
  for i in $(seq 0 23); do
    local hpad hval
    hpad=$(printf "%02d" "$i")
    hval=$(echo "$HOURLY_RAW" | awk -v hh="$hpad" '$2==hh{print $1}')
    HOURLY+=("${hval:-0}")
  done

  # Channel counts from run-start messageChannel field
  local CH_COUNTS ch_telegram ch_bluebubbles ch_whatsapp ch_webchat ch_unknown
  CH_COUNTS=$(echo "$starts_msgs" \
    | grep -oE 'messageChannel=[a-z]+' | cut -d= -f2 | sort | uniq -c)
  ch_telegram=$(  echo "$CH_COUNTS" | awk '$2=="telegram"   {print $1}'); ch_telegram="${ch_telegram:-0}"
  ch_bluebubbles=$(echo "$CH_COUNTS" | awk '$2=="bluebubbles"{print $1}'); ch_bluebubbles="${ch_bluebubbles:-0}"
  ch_whatsapp=$(  echo "$CH_COUNTS" | awk '$2=="whatsapp"   {print $1}'); ch_whatsapp="${ch_whatsapp:-0}"
  ch_webchat=$(   echo "$CH_COUNTS" | awk '$2=="webchat"    {print $1}'); ch_webchat="${ch_webchat:-0}"
  ch_unknown=$(   echo "$CH_COUNTS" | awk '$2=="unknown"    {print $1}'); ch_unknown="${ch_unknown:-0}"

  # LLM fallback if log has content but zero runs
  if [[ "$total_done" -eq 0 && "$LOG_LINE_COUNT" -gt 100 ]]; then
    local llm_hint
    llm_hint=$(llm_parse_fallback "$(head -20 "$LOG_FILE" 2>/dev/null)" \
      "total embedded run done events" 2>/dev/null || echo "")
    [[ -n "$llm_hint" ]] && out "" && out "(Note: 0 runs parsed; LLM hint: $llm_hint)"
  fi

  # ── Cost aggregation from session cache ──────────────────────────────────────
  local COST_STATS
  COST_STATS=$(jq -rcs '
    [.[] | select(.t=="cost")] |
    if length==0 then "" else
      reduce .[] as $r ({inp:0,out:0,cr:0,cost:0,turns:0,mr:{},mc:{}};
        .inp+=$r.inp | .out+=$r.out | .cr+=$r.cr | .cost+=$r.cost | .turns+=1 |
        .mr[$r.prov+"/"+$r.model]+=1 |
        .mc[$r.prov+"/"+$r.model]+=$r.cost
      ) |
      "inp=\(.inp|floor)",
      "out=\(.out|floor)",
      "cr=\(.cr|floor)",
      "cost=\(.cost)",
      "turns=\(.turns)",
      (.mr|to_entries[]|"mr_\(.key)=\(.value)"),
      (.mc|to_entries[]|"mc_\(.key)=\(.value)")
    end
  ' "$SCACHE" 2>/dev/null || echo "")
  local total_input total_output total_cacheread total_cost cost_turns
  total_input=$(   echo "$COST_STATS" | awk -F= '/^inp=/ {print $2}');   total_input="${total_input:-0}"
  total_output=$(  echo "$COST_STATS" | awk -F= '/^out=/ {print $2}');   total_output="${total_output:-0}"
  total_cacheread=$(echo "$COST_STATS" | awk -F= '/^cr=/  {print $2}'); total_cacheread="${total_cacheread:-0}"
  total_cost=$(    echo "$COST_STATS" | awk -F= '/^cost=/{print $2}');   total_cost="${total_cost:-0}"
  cost_turns=$(    echo "$COST_STATS" | awk -F= '/^turns=/{print $2}');  cost_turns="${cost_turns:-0}"

  # ── Tool usage ────────────────────────────────────────────────────────────────
  local TOOL_COUNTS EXEC_CMDS
  TOOL_COUNTS=$(jq -r 'select(.t=="tool") | .name' "$SCACHE" 2>/dev/null \
    | sort | uniq -c | sort -rn)
  EXEC_CMDS=$(jq -r 'select(.t=="tool" and .name=="exec") | .cmd' "$SCACHE" 2>/dev/null \
    | awk '{
        if (match($0,/[^ \/]+\.sh/)) key=substr($0,RSTART,RLENGTH)
        else if ($0~/^curl/) key="curl"
        else { split($0,a," "); key=a[1]; sub(/.*\//,"",key) }
        if (key!="") c[key]++
      } END {for(k in c) print c[k], k}' | sort -rn | head -5)

  # ── Skills ────────────────────────────────────────────────────────────────────
  local NEXUS_LOG="$AGENT_WORKSPACE/logs/nexus-search.log"
  local nexus_total=0 nexus_mcp=0
  if [[ -f "$NEXUS_LOG" ]]; then
    nexus_total=$(wc -l < "$NEXUS_LOG" | tr -d ' ')
    nexus_mcp=$(awk '/mcp.*ok|status.*ok/{c++} END{print c+0}' "$NEXUS_LOG")
  fi
  local nexus_fallback=$(( nexus_total - nexus_mcp ))

  local nexus_exec fashion_exec style_exec
  nexus_exec=$(jq -r 'select(.t=="tool" and .name=="exec") | .cmd' "$SCACHE" 2>/dev/null \
    | awk '/shopify-nexus|shopify-mcp|nexus/{c++} END{print c+0}')
  fashion_exec=$(jq -r 'select(.t=="tool" and .name=="exec") | .cmd' "$SCACHE" 2>/dev/null \
    | awk '/fashion-radar/{c++} END{print c+0}')
  style_exec=$(jq -r 'select(.t=="tool" and .name=="exec") | .cmd' "$SCACHE" 2>/dev/null \
    | awk '/style-profile/{c++} END{print c+0}')
  [[ "$nexus_total" -gt 0 ]] && nexus_exec="$nexus_total"

  # ── Errors & warnings ─────────────────────────────────────────────────────────
  local error_count warn_count
  error_count=$(jq -r 'select(.t=="error") | .ts' "$EVTFILE" 2>/dev/null | awk 'END{print NR}')
  warn_count=$(  jq -r 'select(.t=="warn")  | .ts' "$EVTFILE" 2>/dev/null | awk 'END{print NR}')

  local TOP_ERRORS TOP_WARNS
  TOP_ERRORS=$(jq -r 'select(.t=="error") | .msg' "$EVTFILE" 2>/dev/null \
    | awk '{k=substr($0,1,80); sub(/[[:space:]]+$/,"",k); c[k]++} END{for(k in c) if(k!="") print c[k], k}' \
    | sort -rn | head -5)
  TOP_WARNS=$(jq -r 'select(.t=="warn") | .msg' "$EVTFILE" 2>/dev/null \
    | awk '{k=substr($0,1,80); sub(/[[:space:]]+$/,"",k); c[k]++} END{for(k in c) if(k!="") print c[k], k}' \
    | sort -rn | head -5)

  # ── Historical metrics ─────────────────────────────────────────────────────────
  local avg_r7="" avg_r30="" avg_r90="" avg_c7="" avg_c30="" avg_c90=""
  local hist_count=0
  if [[ -f "$METRICS_FILE" ]]; then
    local T_EPOCH
    T_EPOCH=$(date -jf "%Y-%m-%d" "$REPORT_DATE" +%s 2>/dev/null \
      || date -d "$REPORT_DATE" +%s 2>/dev/null || echo 0)
    local HSTATS
    HSTATS=$(jq -rs --arg today "$REPORT_DATE" --argjson epoch "$T_EPOCH" '
      [.[] | select(.date != $today)] |
      if length==0 then "" else
        def ago(d): (d|strptime("%Y-%m-%d")|mktime) as $dt | (($epoch-$dt)/86400)|floor;
        def avg(a;f): if (a|length)==0 then 0 else (a|map(.[f]//0)|add)/(a|length) end;
        { d7:  [.[] | select(ago(.date)<=7  and ago(.date)>0)],
          d30: [.[] | select(ago(.date)<=30 and ago(.date)>0)],
          d90: [.[] | select(ago(.date)<=90 and ago(.date)>0)] } |
        "n=\((.d30|length))",
        "r7=\(avg(.d7;"runs_total"))",  "r30=\(avg(.d30;"runs_total"))",  "r90=\(avg(.d90;"runs_total"))",
        "c7=\(avg(.d7;"cost_total"))",  "c30=\(avg(.d30;"cost_total"))",  "c90=\(avg(.d90;"cost_total"))"
      end
    ' "$METRICS_FILE" 2>/dev/null || echo "")
    hist_count=$(echo "$HSTATS" | awk -F= '/^n=/{print $2}'); hist_count="${hist_count:-0}"
    avg_r7=$(  echo "$HSTATS" | awk -F= '/^r7=/ {print $2}')
    avg_r30=$( echo "$HSTATS" | awk -F= '/^r30=/{print $2}')
    avg_r90=$( echo "$HSTATS" | awk -F= '/^r90=/{print $2}')
    avg_c7=$(  echo "$HSTATS" | awk -F= '/^c7=/ {print $2}')
    avg_c30=$( echo "$HSTATS" | awk -F= '/^c30=/{print $2}')
    avg_c90=$( echo "$HSTATS" | awk -F= '/^c90=/{print $2}')
  fi

  local delta_runs="" delta_cost=""
  if [[ "$hist_count" -ge 7 ]]; then
    delta_runs=$(delta_label "$total_done" "${avg_r7:-0}" "7d avg")
    delta_cost=$(delta_label "$total_cost" "${avg_c7:-0}" "7d avg")
  fi

  local ANOMALIES=""
  if [[ "$hist_count" -ge 30 ]]; then
    ANOMALIES=$(awk -v tr="$total_done" -v ar="${avg_r30:-0}" \
                    -v tc="$total_cost"  -v ac="${avg_c30:-0}" \
                    -v te="$error_count" \
      'BEGIN {
        if (ar>0) { p=(tr-ar)/ar*100; if(p>50||p<-50) printf "  ⚠ Runs %+.0f%% vs 30d avg (%.1f)\n",p,ar }
        if (ac>0) { p=(tc-ac)/ac*100; if(p>50||p<-50) printf "  ⚠ Cost %+.0f%% vs 30d avg ($%.4f)\n",p,ac }
        if (ar>0&&te>2&&te>ar*0.05) printf "  ⚠ %d errors — elevated, check Errors section\n",te
      }' 2>/dev/null)
  fi

  # ── Config snapshot ────────────────────────────────────────────────────────────
  local primary_model fallbacks hb_interval hb_model
  local tg_s tg_stream bb_s bb_dm wa_s ws_s wf_s wf_maxc exec_bgms skills_list
  if [[ -f "$CONFIG_FILE" ]]; then
    primary_model=$(cfgq '.agents.defaults.model.primary//"unknown"')
    fallbacks=$(    cfgq '[.agents.defaults.model.fallbacks[]?]|join(", ")')
    hb_interval=$(  cfgq '.agents.defaults.heartbeat.every//"disabled"')
    hb_model=$(     cfgq '.agents.defaults.heartbeat.model//""')
    tg_s=$(         cfgq 'if .channels.telegram.enabled then "✓" else "✗" end')
    tg_stream=$(    cfgq '.channels.telegram.streamMode//"default"')
    bb_s=$(         cfgq 'if .channels.bluebubbles.enabled then "✓" else "✗" end')
    bb_dm=$(        cfgq '.channels.bluebubbles.dmPolicy//"default"')
    wa_s=$(         cfgq 'if (.channels.whatsapp.enabled//false) then "✓" else "✗" end')
    ws_s=$(         cfgq 'if (.tools.web.search.enabled//false) then "✓ enabled" else "✗ disabled" end')
    wf_s=$(         cfgq 'if (.tools.web.fetch.enabled//true)   then "✓ enabled" else "✗ disabled" end')
    wf_maxc=$(      cfgq '.tools.web.fetch.maxChars//"default"')
    exec_bgms=$(    cfgq '.tools.exec.backgroundMs//"default"')
    skills_list=$(  cfgq '[.skills.entries//{}|to_entries[]|select(.value.enabled//true)|"  ✓ "+.key]|join("\n")')
  else
    primary_model="(config not found)"; fallbacks=""; hb_interval="?"; hb_model=""
    tg_s="?"; tg_stream=""; bb_s="?"; bb_dm=""; wa_s="?"
    ws_s="?"; wf_s="?"; wf_maxc="?"; exec_bgms="?"; skills_list=""
  fi

  # ── Git changes ────────────────────────────────────────────────────────────────
  local NEXT_DATE GIT_LOG=""
  NEXT_DATE=$(date -v+1d -jf "%Y-%m-%d" "$REPORT_DATE" +%Y-%m-%d 2>/dev/null \
    || date -d "$REPORT_DATE +1 day" +%Y-%m-%d 2>/dev/null || echo "")
  [[ -n "$NEXT_DATE" ]] && GIT_LOG=$(git -C "$IRONCLAW_ROOT" log --oneline \
    --after="${REPORT_DATE}T00:00:00" --before="${NEXT_DATE}T00:00:00" \
    2>/dev/null | head -10 || echo "")

  # ═══════════════════════════════════════════════════════════════
  #  REPORT SECTIONS
  # ═══════════════════════════════════════════════════════════════

  # ── 2. Activity Overview ────────────────────────────────────────
  section "ACTIVITY OVERVIEW"
  if [[ "$total_done" -eq 0 ]]; then
    out "No runs recorded for ${REPORT_DATE}."
  else
    local upct hbpct spark
    upct=$((  total_done>0 ? user_runs*100/total_done : 0 ))
    hbpct=$(( total_done>0 ? heartbeat_count*100/total_done : 0 ))
    spark=$(sparkline "${HOURLY[@]}" 2>/dev/null || echo "")
    outf '%-24s %s%s'  "Total runs:"        "$total_done"      "${delta_runs:+  $delta_runs}"
    outf '  %-22s %-6s (%s%%)' "User-initiated:"  "$user_runs"       "$upct"
    outf '  %-22s %-6s (%s%%)' "Heartbeat runs:"  "$heartbeat_count" "$hbpct"
    outf '%-24s %s s'  "Avg run duration:"  "$avg_dur_s"
    outf '%-24s %s s%s' "Peak run duration:" "$max_dur_s" \
      "${max_dur_at:+  (at $max_dur_at)}"
    outf '%-24s %s'    "Runs >30s:"         "$over30"
    outf '%-24s %s'    "Unique sessions:"   "$uniq_sessions"
    outf '%-24s |%s| (00–23h)' "Runs per hour:" "$spark"
  fi

  # ── 3. Cost & Tokens ────────────────────────────────────────────
  section "COST & TOKENS"
  if [[ "$cost_turns" -eq 0 ]]; then
    out "No session cost data for ${REPORT_DATE}."
  else
    local avg_cpr
    avg_cpr=$(awk -v c="$total_cost" -v r="$total_done" 'BEGIN{printf "%.4f",(r>0?c/r:0)}')
    outf '%-24s %s%s' "Total cost:" "$(fmt_cost "$total_cost")" \
      "${delta_cost:+  $delta_cost}"
    outf '  %-22s %s' "Input tokens:"  "$(fmt_num "$total_input")"
    outf '  %-22s %s' "Output tokens:" "$(fmt_num "$total_output")"
    outf '  %-22s %s' "Cache reads:"   "$(fmt_num "$total_cacheread")"
    outf '  %-22s %s' "Turns counted:" "$cost_turns"
    out ""
    out "Model breakdown:"
    # Use awk directly on COST_STATS to avoid pipe-subshell scoping issues
    echo "$COST_STATS" | awk -v td="$total_done" '
      /^mr_/ { line=substr($0,4); eq=index(line,"="); models[substr(line,1,eq-1)]=substr(line,eq+1)+0 }
      /^mc_/ { line=substr($0,4); eq=index(line,"="); costs[substr(line,1,eq-1)]=substr(line,eq+1)+0 }
      END {
        for (m in models) {
          pct = (td+0>0) ? int(models[m]*100/(td+0)) : 0
          printf "  %-32s %3d runs   $%.4f  (%d%%)\n", m, models[m], costs[m]+0, pct
        }
      }
    ' >> "$OUTBUF"
    out ""
    outf '%-24s $%s' "Avg cost/run:" "$avg_cpr"
  fi

  # ── 4. Channel Activity ──────────────────────────────────────────
  section "CHANNEL ACTIVITY"
  outf '%-20s %s conversations' "Telegram:"    "$ch_telegram"
  outf '%-20s %s conversations' "BlueBubbles:" "$ch_bluebubbles"
  outf '%-20s %s conversations' "WhatsApp:"    "$ch_whatsapp"
  outf '%-20s %s conversations' "Webchat/HTTP:" "$ch_webchat"
  [[ "$ch_unknown" -gt 0 ]] && outf '%-20s %s conversations' "Unknown:" "$ch_unknown"
  local ph=0 pv=0
  for i in $(seq 0 23); do
    local hv="${HOURLY[$i]:-0}"
    [[ "$hv" -gt "$pv" ]] 2>/dev/null && { pv="$hv"; ph="$i"; }
  done
  [[ "$pv" -gt 0 ]] && outf '%-20s %02d:00–%02d:00  (%s runs)' \
    "Peak hour:" "$ph" "$(( (ph+1)%24 ))" "$pv"

  # ── 5. Tool Usage ───────────────────────────────────────────────
  section "TOOL USAGE"
  if [[ -z "$TOOL_COUNTS" ]]; then
    out "No tool calls found in session data for ${REPORT_DATE}."
  else
    echo "$TOOL_COUNTS" | awk '{
      cnt=$1; $1=""; sub(/^ /,""); name=$0
      printf "  %-22s %s calls\n", name, cnt
    }' >> "$OUTBUF"
    if [[ -n "$EXEC_CMDS" ]]; then
      out ""; out "Top exec commands:"
      echo "$EXEC_CMDS" | awk '{
        cnt=$1; $1=""; sub(/^ /,""); cmd=$0
        printf "  %-28s %s\n", cmd, cnt
      }' >> "$OUTBUF"
    fi
  fi

  # ── 6. Skills & Nexus ───────────────────────────────────────────
  section "SKILLS & NEXUS"
  local any_skill=false
  [[ "$nexus_exec" -gt 0 ]]   && { outf '  %-20s %s searches' "shopify-nexus:" "$nexus_exec"; any_skill=true; }
  [[ "$fashion_exec" -gt 0 ]] && { outf '  %-20s %s scans'    "fashion-radar:" "$fashion_exec"; any_skill=true; }
  [[ "$style_exec" -gt 0 ]]   && { outf '  %-20s %s calls'    "style-profile:" "$style_exec"; any_skill=true; }
  [[ "$any_skill" == false ]] && out "  (no skill invocations detected)"
  if [[ "$nexus_total" -gt 0 && -f "$NEXUS_LOG" ]]; then
    local mpc=0
    [[ "$nexus_total" -gt 0 ]] && mpc=$(( nexus_mcp*100/nexus_total ))
    out ""
    outf '  %-22s %s (%s%%)' "Nexus MCP ok:"  "$nexus_mcp"      "$mpc"
    outf '  %-22s %s (%s%%)' "Web fallback:"  "$nexus_fallback"  "$(( 100-mpc ))"
    local ntop
    ntop=$(grep -oE 'domain=[^ ,]+' "$NEXUS_LOG" 2>/dev/null \
      | cut -d= -f2 | sort | uniq -c | sort -rn | head -5)
    if [[ -n "$ntop" ]]; then
      out ""; out "  Top searched domains:"
      echo "$ntop" | awk '{printf "    %-24s %s\n",$2,$1}' >> "$OUTBUF"
    fi
  fi

  # ── 7. Errors & Warnings ────────────────────────────────────────
  section "ERRORS & WARNINGS"
  outf '%-16s %s' "Errors:" "$error_count"
  if [[ -n "$TOP_ERRORS" && "$error_count" -gt 0 ]]; then
    echo "$TOP_ERRORS" | awk '{
      cnt=$1; $1=""; sub(/^ /,"")
      printf "  %sx  %s\n", cnt, substr($0,1,80)
    }' >> "$OUTBUF"
  fi
  out ""
  outf '%-16s %s' "Warnings:" "$warn_count"
  if [[ -n "$TOP_WARNS" && "$warn_count" -gt 0 ]]; then
    echo "$TOP_WARNS" | awk '{
      cnt=$1; $1=""; sub(/^ /,"")
      printf "  %sx  %s\n", cnt, substr($0,1,80)
    }' >> "$OUTBUF"
  fi

  # ── 8. Config Snapshot ──────────────────────────────────────────
  section "CONFIG SNAPSHOT (as of report time)"
  outf '%-24s %s' "Primary model:" "$primary_model"
  [[ -n "$fallbacks" ]] && outf '%-24s %s' "Fallbacks:" "$fallbacks"
  outf '%-24s every %s  (%s)' "Heartbeat:" "$hb_interval" "$hb_model"
  out ""
  out "Channels:"
  outf '  %s telegram     (streamMode: %s)' "$tg_s" "${tg_stream:-default}"
  outf '  %s bluebubbles  (dmPolicy: %s)'   "$bb_s" "${bb_dm:-default}"
  outf '  %s whatsapp'                       "$wa_s"
  out ""
  out "Tools:"
  outf '  %-14s %s   maxChars: %s' "web_fetch:"  "$wf_s" "$wf_maxc"
  outf '  %-14s %s'                "web_search:" "$ws_s"
  outf '  %-14s ✓ enabled   backgroundMs: %s' "exec:" "$exec_bgms"
  if [[ -n "$skills_list" ]]; then
    out ""; out "Custom skills:"; out "$skills_list"
  fi

  # ── 9. Git Changes ──────────────────────────────────────────────
  section "GIT CHANGES (${REPORT_DATE})"
  if [[ -z "$GIT_LOG" ]]; then
    out "No commits on ${REPORT_DATE}."
  else
    local cc; cc=$(echo "$GIT_LOG" | awk 'NF{c++} END{print c+0}')
    out "${cc} commit(s):"
    echo "$GIT_LOG" | awk '{printf "  %s\n",$0}' >> "$OUTBUF"
  fi

  # ── 10. Historical Perspective ──────────────────────────────────
  if [[ "$hist_count" -ge 7 && -f "$METRICS_FILE" ]]; then
    section "HISTORICAL PERSPECTIVE"
    outf '%-20s %-12s %-12s %-12s %-12s' "" "Today" "7d avg" "30d avg" "90d avg"
    outf '%-20s %-12s %-12s %-12s %-12s' "Total runs:" \
      "$total_done" \
      "$(printf '%.1f' "${avg_r7:-0}")" \
      "$(printf '%.1f' "${avg_r30:-0}")" \
      "$(printf '%.1f' "${avg_r90:-0}")"
    outf '%-20s %-12s %-12s %-12s %-12s' "Cost:" \
      "$(fmt_cost "$total_cost")" \
      "$(fmt_cost "${avg_c7:-0}")" \
      "$(fmt_cost "${avg_c30:-0}")" \
      "$(fmt_cost "${avg_c90:-0}")"
    outf '%-20s %-12s' "Errors:" "$error_count"
    if [[ -n "$ANOMALIES" ]]; then
      out ""; out "Anomalies:"; out "$ANOMALIES"
    fi
    local TREND_DATA
    TREND_DATA=$(jq -r 'select(.date!=null) | [.date,(.runs_total//0)]|@tsv' \
      "$METRICS_FILE" 2>/dev/null | sort | tail -14)
    if [[ -n "$TREND_DATA" ]]; then
      local tmax=1
      while IFS=$'\t' read -r _d v; do
        [[ "$v" -gt "$tmax" ]] 2>/dev/null && tmax="$v"
      done <<< "$TREND_DATA"
      out ""; out "Trend (last 14 days, daily runs):"
      while IFS=$'\t' read -r d v; do
        local blen=0 bar=""
        [[ "$tmax" -gt 0 ]] && blen=$(( v*20/tmax ))
        local b; for b in $(seq 1 "$blen" 2>/dev/null); do bar+="█"; done
        outf '  %s %s %s' "$(echo "$d" | cut -c6-)" "$bar" "$v"
      done <<< "$TREND_DATA"
    fi
  fi

  out ""
  printf '═%.0s' $(seq 1 52) >> "$OUTBUF"; printf '\n' >> "$OUTBUF"

  # ── Metrics persistence (--save only) ─────────────────────────────
  if [[ "$SAVE" == true ]]; then
    mkdir -p "$REPORT_DIR"
    local TODAY_JSON
    TODAY_JSON=$(jq -nc \
      --arg  date  "$REPORT_DATE"          \
      --argjson rt "${total_done:-0}"      \
      --argjson ru "${user_runs:-0}"       \
      --argjson rh "${heartbeat_count:-0}" \
      --argjson ss "${uniq_sessions:-0}"   \
      --argjson ct "${total_cost:-0}"      \
      --argjson it "${total_input:-0}"     \
      --argjson ot "${total_output:-0}"    \
      --argjson cr "${total_cacheread:-0}" \
      --argjson er "${error_count:-0}"     \
      --argjson wn "${warn_count:-0}"      \
      --argjson tg "${ch_telegram:-0}"     \
      --argjson bb "${ch_bluebubbles:-0}"  \
      --argjson wa "${ch_whatsapp:-0}"     \
      '{date:$date, runs_total:$rt, runs_user:$ru, runs_heartbeat:$rh,
        sessions:$ss, cost_total:$ct, input_tok:$it, output_tok:$ot,
        cacheread_tok:$cr, errors:$er, warnings:$wn,
        channels:{telegram:$tg, bluebubbles:$bb, whatsapp:$wa}}' 2>/dev/null \
      || echo '{}')
    local TMP_M
    TMP_M=$(mktemp /tmp/dr-metrics-XXXXXX.jsonl)
    [[ -f "$METRICS_FILE" ]] && \
      jq -c --arg d "$REPORT_DATE" 'select(.date!=$d)' "$METRICS_FILE" \
      >> "$TMP_M" 2>/dev/null || true
    echo "$TODAY_JSON" >> "$TMP_M"
    mv "$TMP_M" "$METRICS_FILE"
    # Raw event archive
    mkdir -p "$REPORT_DIR/raw"
    cp "$EVTFILE" "$REPORT_DIR/raw/${REPORT_DATE}.jsonl" 2>/dev/null || true
  fi

  _flush "$REPORT_OUTFILE"
  rm -f "$EVTFILE" "$SCACHE" "$OUTBUF"
}

_flush() {
  local outfile="${1:-}"
  if [[ -n "$outfile" ]]; then
    tee "$outfile" < "$OUTBUF"
    printf '\nReport saved: %s\n' "$outfile" >&2
  else
    cat "$OUTBUF"
  fi
}

# ── Entry point ────────────────────────────────────────────────────────────────
if [[ "$ALL_AGENTS" == true ]]; then
  for name in $(list_agent_dirs); do
    resolve_agent "$name"; generate_report; echo ""
  done
else
  resolve_agent "$AGENT_ARG"; generate_report
fi
