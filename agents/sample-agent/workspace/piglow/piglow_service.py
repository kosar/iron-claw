#!/usr/bin/env python3
"""
PiGlow signal service for pibot. Runs on the Raspberry Pi host.
Accepts GET/POST /signal?state=<name> and /health. Never crashes; all errors caught.
Port: 18793. Override with PIGLOW_PORT. Bind 0.0.0.0 so container (host.docker.internal) can reach.
"""

import json
import os
import sys
from urllib.parse import parse_qs, urlparse

# Ensure we can load piglow_led from same directory
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

DEFAULT_PORT = 18793
VALID_STATES = frozenset({"off", "idle", "thinking", "success", "warning", "error", "attention", "ready"})


def main():
    port = int(os.environ.get("PIGLOW_PORT", DEFAULT_PORT))
    try:
        from http.server import HTTPServer, BaseHTTPRequestHandler
    except ImportError:
        sys.exit(1)

    try:
        import piglow_led
    except Exception:
        piglow_led = None

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self._safe_handle()

        def do_POST(self):
            self._safe_handle()

        def _safe_handle(self):
            try:
                self._handle()
            except Exception:
                self._json(200, {"ok": True, "piglow_available": bool(piglow_led and piglow_led.is_available())})

        def _handle(self):
            path = urlparse(self.path).path.rstrip("/")
            if path == "/health":
                avail = bool(piglow_led and piglow_led.is_available())
                self._json(200, {"ok": True, "piglow_available": avail})
                return
            if path == "/signal":
                q = parse_qs(urlparse(self.path).query)
                state = (q.get("state") or [None])[0] or "off"
                state = (state or "off").strip().lower()
                if state not in VALID_STATES:
                    state = "off"
                if piglow_led and piglow_led.is_available():
                    piglow_led.set_state(state)
                self._json(200, {"ok": True, "state": state, "piglow_available": True})
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
    except OSError:
        sys.exit(1)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if piglow_led and piglow_led.is_available():
            try:
                piglow_led.off()
            except Exception:
                pass


if __name__ == "__main__":
    main()
