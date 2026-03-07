#!/usr/bin/env bash
# PiGlow detection and dependency check (no demo). Use this on the Pi host to verify
# I2C and sn3218 before running the pibot PiGlow service (workspace/piglow/piglow_service.py).
# Usage: ./scripts/piglow-test.sh [--install]
#   --install  Install sn3218 (via Pimoroni-PiGlow) if missing.

set -e
PIGLOW_I2C_ADDR="0x54"

echo "=== PiGlow detection (interface only) ==="
echo ""

# --- I2C detection ---
if ! command -v i2cdetect &>/dev/null; then
  echo "i2cdetect not found. Install with: sudo apt-get install i2c-tools"
  exit 1
fi

I2C_BUSES=()
for f in /dev/i2c-*; do
  [ -e "$f" ] && I2C_BUSES+=("$(basename "$f")")
done
if [ ${#I2C_BUSES[@]} -eq 0 ]; then
  echo "No I2C buses found (/dev/i2c-*). Enable I2C:"
  echo "  sudo raspi-config → Interface Options → I2C → Enable"
  echo "  Or add to /boot/firmware/config.txt: dtparam=i2c_arm=on"
  echo "  Then reboot."
  exit 1
fi

echo "I2C buses: ${I2C_BUSES[*]}"
FOUND_BUS=""
for bus in "${I2C_BUSES[@]}"; do
  bus_num="${bus#i2c-}"
  out="$(sudo i2cdetect -y "$bus_num" 2>/dev/null)" || true
  if echo "$out" | grep -q "54"; then
    FOUND_BUS="$bus (0x54 = PiGlow)"
    break
  fi
done

if [ -n "$FOUND_BUS" ]; then
  echo "PiGlow detected on $FOUND_BUS"
else
  echo "PiGlow (I2C 0x54) not detected on any bus. Check seating and orientation (pinout.xyz/pinout/piglow)."
  for bus in "${I2C_BUSES[@]}"; do
    bus_num="${bus#i2c-}"
    echo ""
    echo "Scan $bus:"
    sudo i2cdetect -y "$bus_num" 2>/dev/null || true
  done
fi

# --- Python / sn3218 (needed for host PiGlow service) ---
if ! command -v python3 &>/dev/null; then
  echo "python3 not found. Install with: sudo apt-get install python3"
  exit 1
fi

if ! python3 -c "import sn3218" 2>/dev/null; then
  echo "sn3218 not found (required for pibot PiGlow service)."
  if [ "${1:-}" = "--install" ]; then
    echo "Installing (sudo required)..."
    if sudo pip3 install --break-system-packages Pimoroni-PiGlow 2>/dev/null; then
      echo "Installed (sn3218 as dependency)."
    else
      echo "Install failed. Try: sudo pip3 install --break-system-packages Pimoroni-PiGlow"
      exit 1
    fi
  else
    echo "Install with: $0 --install"
    exit 1
  fi
else
  echo "sn3218 OK."
fi

echo ""
echo "To run the pibot PiGlow service on the host: python3 agents/pibot/workspace/piglow/piglow_service.py"
