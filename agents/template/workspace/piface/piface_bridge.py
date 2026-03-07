#!/usr/bin/env python3
"""
PiFace CAD display bridge for pibot. Runs on the Raspberry Pi host.
Accepts GET /display?l1=...&l2=...&backlight=1, GET /admin_stats?user=...&action=...&bal=..., GET /health.
Uses pifacecad when available; otherwise still responds 200 so the container's curl succeeds.
Port: 18794. Override with PIFACE_DISPLAY_PORT. Bind 0.0.0.0 so container (host.docker.internal) can reach.
"""

import json
import os
import sys
from urllib.parse import parse_qs, unquote, urlparse

DEFAULT_PORT = 18794
LCD_COLS = 16
LCD_ROWS = 2


def get_cad():
    """Return PiFaceCAD instance or None if not available."""
    try:
        # On Pi 5 / newer kernels, sysfs GPIO interrupt setup can fail. We only need the LCD;
        # no-op the failing call so init_board() can succeed.
        try:
            import pifacecommon.interrupts as _pi_irq
            _pi_irq.bring_gpio_interrupt_into_userspace = lambda: None
        except Exception:
            pass
        import pifacecad
        cad = pifacecad.PiFaceCAD()
        cad.lcd.blink_off()
        cad.lcd.cursor_off()
        return cad
    except Exception:
        return None


def write_two_lines(cad, line1: str, line2: str, backlight: bool = True):
    """Write two lines to the LCD (16 chars each). Clears and writes."""
    if cad is None:
        return
    line1 = (line1 or "")[:LCD_COLS].ljust(LCD_COLS)
    line2 = (line2 or "")[:LCD_COLS].ljust(LCD_COLS)
    cad.lcd.clear()
    cad.lcd.set_cursor(0, 0)
    cad.lcd.write(line1)
    cad.lcd.set_cursor(0, 1)
    cad.lcd.write(line2)
    if backlight:
        cad.lcd.backlight_on()
    else:
        cad.lcd.backlight_off()


def main():
    port = int(os.environ.get("PIFACE_DISPLAY_PORT", DEFAULT_PORT))
    try:
        from http.server import HTTPServer, BaseHTTPRequestHandler
    except ImportError:
        sys.exit(1)

    cad = get_cad()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self._safe_handle()

        def _safe_handle(self):
            try:
                self._handle()
            except Exception:
                self._json(200, {"ok": True, "piface_available": cad is not None})

        def _handle(self):
            parsed = urlparse(self.path)
            path = parsed.path.rstrip("/")
            q = parse_qs(parsed.query)

            if path == "/health":
                self._json(200, {"ok": True, "piface_available": cad is not None})
                return

            if path == "/display":
                l1 = unquote((q.get("l1") or [""])[0])
                l2 = unquote((q.get("l2") or [""])[0])
                bl = (q.get("backlight") or ["1"])[0].strip() not in ("0", "off", "false")
                write_two_lines(cad, l1, l2, backlight=bl)
                self._json(200, {"ok": True, "piface_available": cad is not None})
                return

            if path == "/admin_stats":
                user = unquote((q.get("user") or ["—"])[0])[:LCD_COLS]
                action = unquote((q.get("action") or ["—"])[0])[:LCD_COLS]
                bal = unquote((q.get("bal") or ["—"])[0])[:LCD_COLS]
                # Show as line1: user / action, line2: balance
                write_two_lines(cad, f"{user} | {action}".strip()[:LCD_COLS], bal, backlight=True)
                self._json(200, {"ok": True, "piface_available": cad is not None})
                return

            self.send_response(404)
            self.end_headers()

        def _json(self, code: int, obj: dict):
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(obj).encode())

        def log_message(self, format, *args):
            pass

    try:
        server = HTTPServer(("0.0.0.0", port), Handler)
    except OSError as e:
        print(f"piface_bridge: could not bind 0.0.0.0:{port}: {e}", file=sys.stderr)
        sys.exit(1)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
