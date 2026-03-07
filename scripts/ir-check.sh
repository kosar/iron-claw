#!/usr/bin/env bash
# IR device check: host and container. Run from repo root.
# Usage: ./scripts/ir-check.sh [agent-name]
# Default agent: pibot
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IRONCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT="${1:-pibot}"
AGENT_DIR="$IRONCLAW_ROOT/agents/$AGENT"
CONTAINER="${AGENT}_secure"
DEVICE="${IR_LIRC_DEVICE:-/dev/lirc0}"

echo "=== IR device check (agent: $AGENT, device: $DEVICE) ==="
echo ""

# Host
echo "1. Host: $DEVICE"
if [[ -e "$DEVICE" ]]; then
  ls -la "$DEVICE"
  perms=$(stat -c "%a" "$DEVICE" 2>/dev/null || stat -f "%Lp" "$DEVICE" 2>/dev/null || echo "?")
  echo "   Permissions: $perms (container user 1000 needs read+write; 666 or 660+group is typical)"
else
  echo "   NOT FOUND. Plug in the IR dongle and ensure mceusb is bound (see docs/IR-DONGLE.md)."
  echo "   List LIRC devices: ls -la /dev/lirc*"
  exit 1
fi
echo ""

# Override
echo "2. Compose override (so container gets the device)"
OVERRIDE="$AGENT_DIR/docker-compose.override.yml"
if [[ -f "$OVERRIDE" ]]; then
  echo "   Found: $OVERRIDE"
  if grep -q "lirc" "$OVERRIDE" 2>/dev/null; then
    echo "   Contains LIRC device passthrough."
  else
    echo "   WARNING: Override exists but may not pass $DEVICE. Expected: devices: - $DEVICE:$DEVICE"
  fi
else
  echo "   NOT FOUND. Create it so the container sees the device:"
  echo "   cp $AGENT_DIR/docker-compose.override.yml.example $OVERRIDE"
  echo "   Then: ./scripts/compose-up.sh $AGENT -d"
  exit 1
fi
echo ""

# Container
echo "3. Container: $CONTAINER"
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
  echo "   Container not running. Start with: ./scripts/compose-up.sh $AGENT -d"
  exit 1
fi
if docker exec "$CONTAINER" ls -la "$DEVICE" 2>/dev/null; then
  echo "   Container can see $DEVICE."
else
  echo "   Container cannot access $DEVICE (missing or permission denied)."
  echo "   On host: sudo chmod 666 $DEVICE  (one-time fix)"
  echo "   For reliable after reboot: sudo cp scripts/99-lirc-permissions.rules /etc/udev/rules.d/ && sudo udevadm control --reload-rules && sudo udevadm trigger"
  echo "   Then restart: ./scripts/compose-up.sh $AGENT -d"
  exit 1
fi
echo ""

# Optional: ir-ctl
echo "4. ir-ctl (for blast)"
if docker exec "$CONTAINER" which ir-ctl &>/dev/null; then
  echo "   Present in container."
else
  echo "   Not found in container. Install v4l-utils in the image or run ir-ctl on the host."
fi
echo ""
echo "If all steps pass, IR control from Telegram (ir-blast skill) should work."
echo "Learn buttons on the host: ./scripts/ir-learn.py"
