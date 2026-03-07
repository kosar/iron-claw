#!/usr/bin/env bash
# Host-side: show PiBot system info on the PiFace LCD (IP, CPU, memory).
# Runs on the Pi host only; does not need the container. Each run overwrites whatever
# is currently on the display. Use at boot and on a timer so the display is swept
# back to system info (IP + CPU% + Mem) even after agent updates.
#
# Usage: ./scripts/piface-system-display.sh
# Optional env: PIFACE_DISPLAY_URL (default http://127.0.0.1:18794/display)

PIFACE_URL="${PIFACE_DISPLAY_URL:-http://127.0.0.1:18794/display}"

# Line 1: "PiBot" + IP (16 chars max). Prefer first non-loopback address.
IP=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i !~ /^127\./) { print $i; exit }}')
[[ -z "$IP" ]] && IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$IP" ]] && IP="no-IP"
L1="PiBot ${IP}"
L1="${L1:0:16}"

# Line 2: CPU% and memory (16 chars). e.g. "Cpu:12% Mem:2G" or "Cpu:5% Mem:765M"
# CPU: sample /proc/stat for 1s (idle/total delta)
_cpu=""
if [[ -r /proc/stat ]]; then
  _s1=$(awk '/^cpu /{sum=$2+$3+$4+$5+$6+$7+$8; idle=$5; print sum-idle, sum}' /proc/stat)
  sleep 1 2>/dev/null || true
  _s2=$(awk '/^cpu /{sum=$2+$3+$4+$5+$6+$7+$8; idle=$5; print sum-idle, sum}' /proc/stat)
  if [[ -n "$_s1" && -n "$_s2" ]]; then
    _used_d=$(( ${_s2%% *} - ${_s1%% *} ))
    _total_d=$(( ${_s2##* } - ${_s1##* } ))
    if [[ "$_total_d" -gt 0 ]]; then
      _pct=$(( _used_d * 100 / _total_d ))
      [[ "$_pct" -gt 100 ]] && _pct=100
      _cpu="Cpu:${_pct}%"
    fi
  fi
fi
[[ -z "$_cpu" ]] && _cpu="Cpu:--%"

# Memory: available (column 7) or free (column 4) from free -m
_mb=""
if command -v free >/dev/null 2>&1; then
  _mb=$(free -m 2>/dev/null | awk '/^Mem:/{avail=$7; free=$4; if(avail~/^[0-9]+$/) print avail; else if(free~/^[0-9]+$/) print free; exit}')
fi
if [[ -n "$_mb" && "$_mb" =~ ^[0-9]+$ ]]; then
  if [[ "$_mb" -ge 1024 ]]; then
    _g=$((_mb / 1024))
    _mem="Mem:${_g}G"
  else
    _mem="Mem:${_mb}M"
  fi
else
  _mem="Mem:--"
fi
L2="${_cpu} ${_mem}"
L2="${L2:0:16}"

curl -sf -m 2 -G \
  --data-urlencode "l1=$L1" \
  --data-urlencode "l2=$L2" \
  "$PIFACE_URL" >/dev/null 2>/dev/null || true
