#!/usr/bin/env python3
"""
PiGlow LED driver — robust, never crashes. Use from the host PiGlow service only.
If PiGlow is not detected or I2C/sn3218 fails, all functions no-op (no raise, no log spam).
Best-practice semantics: idle=dim white, thinking=blue, success=green flash, warning=orange, error=red, attention=yellow flash.

Uses Pimoroni PiGlow physical layout: 3 legs, 6 rings (red, orange, yellow, green, blue, white).
SN3218 channel mapping from Pimoroni piglow.py _legs — each ring has 3 LEDs at specific channels.
"""

from __future__ import annotations

import time
from typing import Optional

# Pimoroni PiGlow: _legs[leg][ring] = SN3218 channel. Ring order: r, o, y, g, b, w (0..5).
_LEGS = [
    [6, 7, 8, 5, 4, 9],   # leg 0: red, orange, yellow, green, blue, white
    [17, 16, 15, 13, 11, 10],
    [0, 1, 2, 3, 14, 12],
]

# For each colour (ring index), the 3 SN3218 channel indices so that colour lights all 3 LEDs.
_CHANNELS_BY_COLOUR = {
    "red": [_LEGS[0][0], _LEGS[1][0], _LEGS[2][0]],       # [6, 17, 0]
    "orange": [_LEGS[0][1], _LEGS[1][1], _LEGS[2][1]],    # [7, 16, 1]
    "yellow": [_LEGS[0][2], _LEGS[1][2], _LEGS[2][2]],    # [8, 15, 2]
    "green": [_LEGS[0][3], _LEGS[1][3], _LEGS[2][3]],    # [5, 13, 3]
    "blue": [_LEGS[0][4], _LEGS[1][4], _LEGS[2][4]],     # [4, 11, 14]
    "white": [_LEGS[0][5], _LEGS[1][5], _LEGS[2][5]],    # [9, 10, 12]
}


def _channels_for_colour(colour: str) -> list[int]:
    return list(_CHANNELS_BY_COLOUR.get(colour, _CHANNELS_BY_COLOUR["white"]))


def _all_colour(colour: str, brightness: int) -> list[int]:
    buf = [0] * 18
    b = min(255, max(0, brightness))
    for ch in _channels_for_colour(colour):
        buf[ch] = b
    return buf


def _all_leds(brightness: int) -> list[int]:
    """All 18 LEDs same brightness — full PiGlow power."""
    b = min(255, max(0, brightness))
    return [b] * 18


_driver: Optional[object] = None
_available: bool = False


def _get_driver(bus: int = 1) -> Optional[object]:
    global _driver, _available
    if _driver is not None:
        return _driver
    if not _available and _driver is None:
        try:
            import sn3218
            _driver = sn3218.SN3218(i2c_bus=bus)
            _driver.enable()
            _driver.enable_leds(0x3FFFF)
            _available = True
        except Exception:
            _available = False
            _driver = None
    return _driver


def is_available() -> bool:
    """Return True if PiGlow was detected and is usable. Safe to call anytime."""
    try:
        d = _get_driver()
        return d is not None
    except Exception:
        return False


def off() -> None:
    """Turn off all LEDs. No-op if PiGlow unavailable."""
    try:
        d = _get_driver()
        if d is None:
            return
        d.output_raw([0] * 18)
    except Exception:
        pass


def set_state(state: str) -> None:
    """
    Set LED state by name. Never raises. One-shot states (success, attention, ready) block briefly then turn off or idle.
    States: off, idle, thinking, success, warning, error, attention, ready.
    """
    state = (state or "").strip().lower() or "off"
    try:
        d = _get_driver()
        if d is None:
            return
        # Brightness levels: avoid full 255 for longevity and comfort
        if state == "off":
            d.output_raw([0] * 18)
            return
        if state == "idle":
            # Dim white, steady — ready and non-distracting
            d.output_raw(_all_colour("white", 12))
            return
        if state == "thinking":
            # Blue = working/loading (universal UX)
            d.output_raw(_all_colour("blue", 70))
            return
        if state == "success":
            # Green, brief hold, then off
            d.output_raw(_all_colour("green", 100))
            time.sleep(0.7)
            d.output_raw([0] * 18)
            return
        if state == "warning":
            # Amber/orange = caution
            d.output_raw(_all_colour("orange", 80))
            return
        if state == "error":
            # Red = failure
            d.output_raw(_all_colour("red", 80))
            return
        if state == "attention":
            # Yellow double-flash then off
            d.output_raw(_all_colour("yellow", 90))
            time.sleep(0.2)
            d.output_raw([0] * 18)
            time.sleep(0.15)
            d.output_raw(_all_colour("yellow", 90))
            time.sleep(0.2)
            d.output_raw([0] * 18)
            return
        if state == "ready":
            # "Open for business" — three clear green flashes then idle (super clear, unmistakable)
            for _ in range(3):
                d.output_raw(_all_colour("green", 120))
                time.sleep(0.4)
                d.output_raw([0] * 18)
                time.sleep(0.25)
            d.output_raw(_all_colour("white", 12))
            return
        # Unknown state: treat as off
        d.output_raw([0] * 18)
    except Exception:
        pass
