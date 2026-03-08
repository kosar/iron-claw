#!/usr/bin/env bash
# shopify-mcp.sh — JSON-RPC 2.0 client for Shopify MCP endpoints
#
# Usage (shell-safe — no JSON quoting needed):
#   shopify-mcp.sh <domain> --discover
#   shopify-mcp.sh <domain> <tool_name> key=value key2=value2 ...
#
# Examples:
#   shopify-mcp.sh allbirds.com --discover
#   shopify-mcp.sh allbirds.com search_shop_catalog query="wool runners" context="browsing"
#   shopify-mcp.sh allbirds.com search_shop_policies_and_faqs query="return policy"
#   shopify-mcp.sh allbirds.com get_product_details product_id="gid://shopify/Product/123"
#
# Dependencies: curl, node (no jq needed — uses Node.js for JSON)
set -euo pipefail

DOMAIN="${1:?Usage: shopify-mcp.sh <domain> [--discover | <tool_name> key=value ...]}"
shift

MCP_URL="https://${DOMAIN}/api/mcp"
TIMEOUT=20
TMPFILE=$(mktemp /tmp/mcp-req-XXXXXX.json)
trap 'rm -f "$TMPFILE"' EXIT

# ── Diagnostic logging ──
LOG_DIR="/tmp/openclaw"
LOG_FILE="${LOG_DIR}/nexus-search.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true

log_event() {
  local event="$1"; shift
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
  local json="{\"timestamp\":\"${ts}\",\"event\":\"${event}\",\"domain\":\"${DOMAIN}\""
  for arg in "$@"; do
    local key="${arg%%=*}" val="${arg#*=}"
    [ "$key" = "$arg" ] && continue
    val=$(printf '%s' "$val" | sed 's/"/\\"/g')
    if printf '%s' "$val" | grep -qE '^[0-9]+$'; then
      json="${json},\"${key}\":${val}"
    else
      json="${json},\"${key}\":\"${val}\""
    fi
  done
  json="${json}}"
  echo "$json" >> "$LOG_FILE" 2>/dev/null || true
}

# Millisecond timer (uses perl for sub-second precision, falls back to seconds)
now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' 2>/dev/null \
    || echo $(( $(date +%s) * 1000 ))
}

# Helper: POST a JSON-RPC request, return body on stdout, exit 1 on failure
# Sets global LAST_HTTP_STATUS for logging
LAST_HTTP_STATUS=0
jsonrpc_post() {
  local body="$1"
  printf '%s' "$body" > "$TMPFILE"

  local resp_file
  resp_file=$(mktemp /tmp/mcp-resp-XXXXXX.json)

  local status
  status=$(curl -sS -L --max-time "$TIMEOUT" \
    -o "$resp_file" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -X POST --data-binary @"$TMPFILE" \
    "$MCP_URL" 2>/dev/null) || { rm -f "$resp_file"; LAST_HTTP_STATUS=0; echo '{"error":"curl failed","code":-1}'; exit 1; }

  LAST_HTTP_STATUS="$status"

  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    local snippet
    snippet=$(head -c 500 "$resp_file")
    rm -f "$resp_file"
    node -e "console.log(JSON.stringify({error:'HTTP $status',body:process.argv[1]}))" "$snippet"
    exit 1
  fi

  cat "$resp_file"
  rm -f "$resp_file"
}

# Step 1: Initialize (protocol handshake)
init_body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ironclaw-nexus","version":"1.0"}}}'
t0=$(now_ms)
init_resp=$(jsonrpc_post "$init_body") || {
  t1=$(now_ms)
  log_event "mcp_handshake" "status=error" "duration_ms=$((t1-t0))" "http_status=${LAST_HTTP_STATUS}" "reason=init request failed"
  echo "$init_resp"
  exit 1
}

# Check for JSON-RPC error in init response
if node -e "const r=JSON.parse(process.argv[1]); if(r.error) process.exit(0); process.exit(1)" "$init_resp" 2>/dev/null; then
  t1=$(now_ms)
  err_reason=$(node -e "const r=JSON.parse(process.argv[1]); console.log((r.error.message||JSON.stringify(r.error)).slice(0,200))" "$init_resp" 2>/dev/null || echo "unknown")
  log_event "mcp_handshake" "status=error" "duration_ms=$((t1-t0))" "http_status=${LAST_HTTP_STATUS}" "reason=${err_reason}"
  echo "$init_resp"
  exit 1
fi

# Step 2: Send initialized notification
notif_body='{"jsonrpc":"2.0","method":"notifications/initialized"}'
jsonrpc_post "$notif_body" >/dev/null 2>&1 || true

t1=$(now_ms)
proto_ver=$(node -e "const r=JSON.parse(process.argv[1]); console.log(r.result&&r.result.protocolVersion||'unknown')" "$init_resp" 2>/dev/null || echo "unknown")
log_event "mcp_handshake" "status=ok" "duration_ms=$((t1-t0))" "http_status=${LAST_HTTP_STATUS}" "protocol_version=${proto_ver}"

# Step 3: Dispatch based on command
if [ "${1:-}" = "--discover" ]; then
  list_body='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  t2=$(now_ms)
  disc_resp=$(jsonrpc_post "$list_body")
  t3=$(now_ms)
  resp_bytes=${#disc_resp}

  # Parse tool names and count
  tool_info=$(node -e '
    const r = JSON.parse(process.argv[1]);
    const tools = (r.result && r.result.tools) || [];
    const names = tools.map(t => t.name).join(",");
    console.log(tools.length + "|" + names);
  ' "$disc_resp" 2>/dev/null || echo "0|")
  tool_count="${tool_info%%|*}"
  tool_names="${tool_info#*|}"

  log_event "mcp_discover" "status=ok" "duration_ms=$((t3-t2))" "http_status=${LAST_HTTP_STATUS}" \
    "tools=${tool_names}" "tool_count=${tool_count}" "response_bytes=${resp_bytes}"

  echo "$disc_resp"
else
  TOOL_NAME="${1:?Missing tool name}"
  shift

  # Build args summary for logging
  args_summary=""
  for a in "$@"; do
    [ -n "$args_summary" ] && args_summary="${args_summary}, "
    args_summary="${args_summary}${a}"
  done

  # Build JSON-RPC tools/call request from key=value pairs using Node.js
  call_body=$(node -e '
    const tool = process.argv[1];
    const args = {};
    for (let i = 2; i < process.argv.length; i++) {
      const eq = process.argv[i].indexOf("=");
      if (eq > 0) {
        args[process.argv[i].slice(0, eq)] = process.argv[i].slice(eq + 1);
      }
    }
    console.log(JSON.stringify({
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: { name: tool, arguments: args }
    }));
  ' "$TOOL_NAME" "$@")

  t2=$(now_ms)
  call_resp=$(jsonrpc_post "$call_body") || {
    t3=$(now_ms)
    log_event "mcp_tool_call" "tool=${TOOL_NAME}" "status=error" "duration_ms=$((t3-t2))" \
      "http_status=${LAST_HTTP_STATUS}" "error_detail=request failed" "args_summary=${args_summary}"
    echo "$call_resp"
    exit 1
  }
  t3=$(now_ms)
  resp_bytes=${#call_resp}

  # Parse product count and sample titles from response
  parse_info=$(node -e '
    try {
      const r = JSON.parse(process.argv[1]);
      if (r.error) {
        console.log("error|0|" + (r.error.message || JSON.stringify(r.error)).slice(0, 200));
        process.exit(0);
      }
      const content = r.result && r.result.content;
      if (!content || !content[0] || !content[0].text) {
        console.log("ok|0|");
        process.exit(0);
      }
      let inner;
      try { inner = JSON.parse(content[0].text); } catch(e) {
        console.log("ok|0|");
        process.exit(0);
      }
      // Try common product array locations
      const products = inner.products || inner.results || inner.items || [];
      if (!Array.isArray(products)) {
        console.log("ok|0|");
        process.exit(0);
      }
      const titles = products.slice(0, 3).map(p => p.title || p.name || "untitled").join(" | ");
      console.log("ok|" + products.length + "|" + titles);
    } catch(e) {
      console.log("ok|0|");
    }
  ' "$call_resp" 2>/dev/null || echo "ok|0|")

  parse_status="${parse_info%%|*}"
  rest="${parse_info#*|}"
  product_count="${rest%%|*}"
  products_sample="${rest#*|}"

  if [ "$parse_status" = "error" ]; then
    log_event "mcp_tool_call" "tool=${TOOL_NAME}" "status=error" "duration_ms=$((t3-t2))" \
      "http_status=${LAST_HTTP_STATUS}" "response_bytes=${resp_bytes}" \
      "error_detail=${products_sample}" "args_summary=${args_summary}"
  else
    log_event "mcp_tool_call" "tool=${TOOL_NAME}" "status=ok" "duration_ms=$((t3-t2))" \
      "http_status=${LAST_HTTP_STATUS}" "response_bytes=${resp_bytes}" \
      "product_count=${product_count}" "products_sample=${products_sample}" "args_summary=${args_summary}"
  fi

  echo "$call_resp"
fi
