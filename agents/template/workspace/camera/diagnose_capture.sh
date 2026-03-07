#!/usr/bin/env bash
# Diagnose why the pibot USB camera capture might fail. Run on the Pi host.
# Usage: bash agents/pibot/workspace/camera/diagnose_capture.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURE_PORT="${CAPTURE_PORT:-18792}"

echo "=== USB camera capture diagnostic (pibot) ==="
echo ""

# 1. Port 18792 — is the capture service running?
echo "1. Capture service (port $CAPTURE_PORT)"
if command -v ss >/dev/null 2>&1; then
  if ss -tlnp 2>/dev/null | grep -q ":$CAPTURE_PORT "; then
    echo "   OK: Something is listening on $CAPTURE_PORT"
  else
    echo "   FAIL: Nothing listening on $CAPTURE_PORT"
    echo "   → Start the capture service on the host:"
    echo "     python3 $SCRIPT_DIR/capture_service.py"
    echo "     Or: systemctl --user start capture-service.service"
    echo ""
  fi
else
  if grep -q ":$CAPTURE_PORT " /proc/net/tcp 2>/dev/null; then
    echo "   OK: Port $CAPTURE_PORT in use"
  else
    echo "   FAIL: Port $CAPTURE_PORT not in use (service not running?)"
    echo "   → Start: python3 $SCRIPT_DIR/capture_service.py"
    echo ""
  fi
fi

# 2. /dev/video*
echo "2. USB video devices"
if ls /dev/video* 1>/dev/null 2>&1; then
  for d in /dev/video*; do
    if [[ -r "$d" ]]; then
      echo "   OK: $d (readable)"
    else
      echo "   FAIL: $d exists but not readable by $(whoami)"
      echo "   → Add your user to the video group: sudo usermod -aG video $(whoami), then log out and back in"
    fi
  done
else
  echo "   FAIL: No /dev/video* devices found"
  echo "   → Check USB camera is connected; run: ls -la /dev/video*"
  echo "   → On Raspberry Pi, ensure the camera is not disabled in config."
fi
echo ""

# 3. ffmpeg
echo "3. ffmpeg"
if command -v ffmpeg >/dev/null 2>&1; then
  echo "   OK: $(ffmpeg -version 2>&1 | head -1)"
else
  echo "   FAIL: ffmpeg not installed"
  echo "   → Install: sudo apt install -y ffmpeg"
fi
echo ""

# 4. workspace/camera writable
echo "4. Workspace camera directory"
if [[ -w "$SCRIPT_DIR" ]]; then
  echo "   OK: $SCRIPT_DIR is writable"
else
  echo "   FAIL: $SCRIPT_DIR not writable by $(whoami)"
  echo "   → Fix ownership or run the capture service as the repo owner"
fi
echo ""

# 5. Hit /capture and show response
echo "5. Test capture endpoint"
resp=$(curl -sf -m 10 -X POST "http://127.0.0.1:$CAPTURE_PORT/capture" 2>/dev/null) || resp=""
if [[ -z "$resp" ]]; then
  echo "   FAIL: No response (service not running or connection refused)"
  echo "   → Start the capture service first (see step 1)"
else
  ok=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ok', False))" 2>/dev/null || echo "false")
  if [[ "$ok" == "True" ]]; then
    echo "   OK: Capture succeeded. Response: $resp"
    if [[ -f "$SCRIPT_DIR/latest.jpg" ]]; then
      echo "   OK: latest.jpg exists ($(stat -c%s "$SCRIPT_DIR/latest.jpg" 2>/dev/null || stat -f%z "$SCRIPT_DIR/latest.jpg" 2>/dev/null) bytes)"
    else
      echo "   FAIL: latest.jpg missing after capture"
    fi
  else
    err=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error', 'unknown'))" 2>/dev/null || echo "unknown")
    echo "   FAIL: Capture failed. Error: $err"
    echo "   → Fix the cause above (device, ffmpeg, permissions) and try again"
  fi
fi
echo ""

# 6. From container (optional hint)
echo "6. Container → host"
echo "   The container reaches the host at host.docker.internal:$CAPTURE_PORT"
echo "   If capture works in step 5 but the agent still fails, check that the container can reach the host:"
echo "   docker exec pibot_secure curl -sf -m 5 http://host.docker.internal:$CAPTURE_PORT/capture || echo 'Container cannot reach host'"
echo ""
echo "=== End diagnostic ==="
