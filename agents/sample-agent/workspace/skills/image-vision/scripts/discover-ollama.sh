#!/usr/bin/env bash
# discover-ollama.sh — Scan LAN for Ollama servers and catalog their models.
# Usage: bash discover-ollama.sh [output-json-path] [--full]
# Output: JSON file with discovered hosts, models, and timestamps.
#
# By default, checks localhost + host.docker.internal + common LAN IPs.
# Use --full to scan the entire /24 subnet (slower, ~30s).
# Requires: bash, curl, python3 (no jq)

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

if [[ -n "$SCAN_SUBNET" ]]; then
  SUBNET="${SCAN_SUBNET%.*}"
  SUBNET="${SUBNET%.*}"
  echo "Using SCAN_SUBNET override: ${SUBNET}.0/24" >&2
else
  LOCAL_IP=$(detect_subnet)
  SUBNET="${LOCAL_IP%.*}"
fi

# Build list of hosts to probe
PROBE_HOSTS=()

if [[ "$FULL_SCAN" == "true" ]]; then
  echo "Full scan: ${SUBNET}.0/24 for Ollama (port $SCAN_PORT)..." >&2
  for i in $(seq 1 254); do
    PROBE_HOSTS+=("${SUBNET}.$i")
  done
else
  echo "Quick scan for Ollama servers (port $SCAN_PORT)..." >&2
  PROBE_HOSTS+=("127.0.0.1" "host.docker.internal" "${SUBNET}.1")
  for i in $(seq 2 20); do PROBE_HOSTS+=("${SUBNET}.$i"); done
  for i in $(seq 100 110); do PROBE_HOSTS+=("${SUBNET}.$i"); done
  for i in $(seq 130 160); do PROBE_HOSTS+=("${SUBNET}.$i"); done
  for i in $(seq 200 210); do PROBE_HOSTS+=("${SUBNET}.$i"); done
  while IFS= read -r arp_ip; do
    [[ -n "$arp_ip" ]] && PROBE_HOSTS+=("$arp_ip")
  done < <(arp -a 2>/dev/null | grep -oE '\([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\)' | tr -d '()')
fi

# Phase 1: Parallel port probe
TMPDIR_SCAN=$(mktemp -d)
trap "rm -rf '$TMPDIR_SCAN'" EXIT

for HOST in "${PROBE_HOSTS[@]}"; do
  (
    if curl -s -o /dev/null --connect-timeout 1 --max-time 2 "http://$HOST:$SCAN_PORT/api/version" 2>/dev/null; then
      echo "$HOST" > "$TMPDIR_SCAN/alive_$HOST"
    fi
  ) &
done

WAIT_START=$SECONDS
while [[ $(jobs -r | wc -l) -gt 0 ]]; do
  if (( SECONDS - WAIT_START > MAX_WAIT )); then
    jobs -p 2>/dev/null | xargs kill 2>/dev/null || true
    break
  fi
  sleep 0.2
done
wait 2>/dev/null || true

ALIVE_HOSTS=()
for f in "$TMPDIR_SCAN"/alive_*; do
  [[ -f "$f" ]] || continue
  h=$(cat "$f" 2>/dev/null)
  [[ -n "$h" ]] && ALIVE_HOSTS+=("$h")
done

ALIVE_UNIQ=($(printf '%s\n' "${ALIVE_HOSTS[@]}" | sort -u))
ALIVE_HOSTS=()
for h in 127.0.0.1 host.docker.internal; do
  for u in "${ALIVE_UNIQ[@]}"; do [[ "$u" == "$h" ]] && ALIVE_HOSTS+=("$u") && break; done
done
for u in "${ALIVE_UNIQ[@]}"; do
  [[ "$u" == "127.0.0.1" || "$u" == "host.docker.internal" ]] && continue
  ALIVE_HOSTS+=("$u")
done

echo "Found ${#ALIVE_HOSTS[@]} Ollama server(s)" >&2

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HOSTS_DATA_FILE="$TMPDIR_SCAN/hosts.json"
echo "[]" > "$HOSTS_DATA_FILE"

for HOST in "${ALIVE_HOSTS[@]}"; do
  VERSION_JSON=$(curl -s --max-time 3 "http://$HOST:$SCAN_PORT/api/version" 2>/dev/null || echo "{}")
  TAGS_JSON=$(curl -s --max-time 5 "http://$HOST:$SCAN_PORT/api/tags" 2>/dev/null || echo "{}")

  python3 - "$HOST" "$SCAN_PORT" "$VERSION_JSON" "$TAGS_JSON" "$HOSTS_DATA_FILE" <<'PYEOF'
import sys, json, re

host        = sys.argv[1]
port        = int(sys.argv[2])
version_raw = sys.argv[3]
tags_raw    = sys.argv[4]
out_file    = sys.argv[5]

try:
    version = json.loads(version_raw).get('version', 'unknown')
except Exception:
    version = 'unknown'

try:
    models = [m.get('name', '') for m in json.loads(tags_raw).get('models', []) if m.get('name')]
except Exception:
    models = []

pat = re.compile(r'flux|z-image|stable-diffusion|dall|image', re.I)
image_models = [m for m in models if pat.search(m)]
text_models  = [m for m in models if not pat.search(m)]

entry = {
    'host': host, 'port': port, 'version': version,
    'image_models': image_models, 'text_models': text_models, 'all_models': models
}

with open(out_file, 'r') as f:
    hosts = json.load(f)
hosts.append(entry)
with open(out_file, 'w') as f:
    json.dump(hosts, f)
PYEOF

done

CATALOG=$(python3 - "$HOSTS_DATA_FILE" "$TIMESTAMP" "${SUBNET}.0/24" <<'PYEOF'
import sys, json

hosts_file = sys.argv[1]
ts         = sys.argv[2]
subnet     = sys.argv[3]

with open(hosts_file) as f:
    hosts = json.load(f)

catalog = {
    'scan_timestamp': ts,
    'subnet': subnet,
    'hosts': hosts,
    'image_capable': [
        {'host': h['host'], 'port': h['port'], 'models': h['image_models']}
        for h in hosts if h['image_models']
    ],
    'text_capable': [
        {'host': h['host'], 'port': h['port'], 'models': h['text_models']}
        for h in hosts if h['text_models']
    ]
}
print(json.dumps(catalog, indent=2))
PYEOF
)

if [[ "$OUTPUT" == "/dev/stdout" ]]; then
  echo "$CATALOG"
else
  echo "$CATALOG" > "$OUTPUT"
  echo "Catalog written to $OUTPUT" >&2
fi
