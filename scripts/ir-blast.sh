#!/usr/bin/env bash
# Blast a recorded IR waveform (ir-ctl format) out through the dongle.
# Requires: v4l-utils (ir-ctl). Record with: ./scripts/ir-receive.py --summary --record file.ir
set -e
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <recorded.ir> [device]" >&2
  echo "  device defaults to /dev/lirc0" >&2
  echo "  Record with: ./scripts/ir-receive.py --summary --record file.ir" >&2
  exit 1
fi
FILE="$1"
DEV="${2:-${IR_LIRC_DEVICE:-/dev/lirc0}}"
if [[ ! -f "$FILE" ]]; then
  echo "No such file: $FILE" >&2
  exit 1
fi
if ! command -v ir-ctl &>/dev/null; then
  echo "ir-ctl not found. Install v4l-utils: sudo apt install v4l-utils" >&2
  exit 1
fi
# One blast = one button press. Multiple blasts make the fan see multiple presses (e.g. on then off).
ir-ctl -d "$DEV" -e 1 -c 38000 --send="$FILE"
