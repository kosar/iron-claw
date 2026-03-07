#!/usr/bin/env bash
# discover-ollama.sh — Scan LAN for Ollama servers and catalog their models.
# Usage: bash discover-ollama.sh [output-json-path] [--full]
# Output: JSON file with discovered hosts, models, and timestamps.
#
# By default, checks localhost + host.docker.internal + common LAN IPs.
# Use --full to scan the entire /24 subnet (slower, ~30s).

set -e
OUTPUT="/dev/stdout"
FULL_SCAN=false
SCAN_PORT=11434
MAX_WAIT=15  # max seconds to wait for all parallel probes

for arg in "$@"; do
  case "$arg" in
    --full) FULL_SCAN=true ;;
    *) OUTPUT="$arg" ;;
  esac
done

# Auto-detect local subnet from default interface
detect_subnet() {
  local ip
  # macOS
  ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
  # Linux fallback
  [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  # Docker bridge fallback
  [[ -z "$ip" ]] && ip=$(ip route 2>/dev/null | grep default | awk '{print $3}' | head -1)

  if [[ -z "$ip" ]]; then
    echo "ERROR: Could not detect local IP" >&2
    exit 1
  fi

  echo "$ip"
}

LOCAL_IP=$(detect_subnet)
SUBNET="${LOCAL_IP%.*}"

# Build list of hosts to probe
PROBE_HOSTS=()

if [[ "$FULL_SCAN" == "true" ]]; then
  echo "Full scan: ${SUBNET}.0/24 for Ollama (port $SCAN_PORT)..." >&2
  for i in $(seq 1 254); do
    PROBE_HOSTS+=("${SUBNET}.$i")
  done
else
  echo "Quick scan for Ollama servers (port $SCAN_PORT)..." >&2
  # Common hosts: localhost, docker bridge, gateway (.1)
  PROBE_HOSTS+=("127.0.0.1" "host.docker.internal" "${SUBNET}.1")
  # Add .2-.20 and .100-.110 (common static IP ranges for servers)
  for i in $(seq 2 20); do PROBE_HOSTS+=("${SUBNET}.$i"); done
  for i in $(seq 100 110); do PROBE_HOSTS+=("${SUBNET}.$i"); done
  # Add .200-.210 (another common range)
  for i in $(seq 200 210); do PROBE_HOSTS+=("${SUBNET}.$i"); done
  # Add every known host from ARP table (these are confirmed-alive on LAN)
  while IFS= read -r arp_ip; do
    [[ -n "$arp_ip" ]] && PROBE_HOSTS+=("$arp_ip")
  done < <(arp -a 2>/dev/null | grep -oE '\([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\)' | tr -d '()')
fi

# Phase 1: Parallel port probe using curl (more reliable timeout than nc on macOS)
TMPDIR_SCAN=$(mktemp -d)
trap "rm -rf '$TMPDIR_SCAN'" EXIT

for HOST in "${PROBE_HOSTS[@]}"; do
  (
    # Use curl with strict connect timeout — much more reliable than nc on macOS
    if curl -s -o /dev/null --connect-timeout 1 --max-time 2 "http://$HOST:$SCAN_PORT/api/version" 2>/dev/null; then
      echo "$HOST" > "$TMPDIR_SCAN/alive_$HOST"
    fi
  ) &
done

# Wait for all probes with a hard timeout
WAIT_START=$SECONDS
while [[ $(jobs -r | wc -l) -gt 0 ]]; do
  if (( SECONDS - WAIT_START > MAX_WAIT )); then
    # Kill any remaining probes
    jobs -p 2>/dev/null | xargs kill 2>/dev/null || true
    break
  fi
  sleep 0.2
done
wait 2>/dev/null || true

# Collect alive hosts
ALIVE_HOSTS=()
for f in "$TMPDIR_SCAN"/alive_*; do
  [[ -f "$f" ]] || continue
  h=$(cat "$f" 2>/dev/null)
  [[ -n "$h" ]] && ALIVE_HOSTS+=("$h")
done

# Deduplicate (127.0.0.1 and localhost might both resolve)
ALIVE_HOSTS=($(printf '%s\n' "${ALIVE_HOSTS[@]}" | sort -u))

echo "Found ${#ALIVE_HOSTS[@]} Ollama server(s)" >&2

# Phase 2: Query each host for version + model list
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HOSTS_JSON="["

for i in "${!ALIVE_HOSTS[@]}"; do
  HOST="${ALIVE_HOSTS[$i]}"
  VERSION=$(curl -s --max-time 3 "http://$HOST:$SCAN_PORT/api/version" 2>/dev/null | jq -r '.version // "unknown"' 2>/dev/null || echo "unknown")
  MODELS=$(curl -s --max-time 5 "http://$HOST:$SCAN_PORT/api/tags" 2>/dev/null | jq -c '[.models[]?.name] // []' 2>/dev/null || echo "[]")
  IMAGE_MODELS=$(echo "$MODELS" | jq -c '[.[] | select(test("flux|z-image|stable-diffusion|dall|image"))]' 2>/dev/null || echo "[]")
  TEXT_MODELS=$(echo "$MODELS" | jq -c '[.[] | select(test("flux|z-image|stable-diffusion|dall|image") | not)]' 2>/dev/null || echo "[]")

  [[ $i -gt 0 ]] && HOSTS_JSON+=","
  HOSTS_JSON+="{\"host\":\"$HOST\",\"port\":$SCAN_PORT,\"version\":\"$VERSION\",\"image_models\":$IMAGE_MODELS,\"text_models\":$TEXT_MODELS,\"all_models\":$MODELS}"
done

HOSTS_JSON+="]"

# Build final catalog
CATALOG=$(jq -n \
  --argjson hosts "$HOSTS_JSON" \
  --arg ts "$TIMESTAMP" \
  --arg subnet "${SUBNET}.0/24" \
  '{
    scan_timestamp: $ts,
    subnet: $subnet,
    hosts: $hosts,
    image_capable: [$hosts[] | select(.image_models | length > 0) | {host: .host, port: .port, models: .image_models}],
    text_capable: [$hosts[] | select(.text_models | length > 0) | {host: .host, port: .port, models: .text_models}]
  }')

if [[ "$OUTPUT" == "/dev/stdout" ]]; then
  echo "$CATALOG"
else
  echo "$CATALOG" > "$OUTPUT"
  echo "Catalog written to $OUTPUT" >&2
fi
