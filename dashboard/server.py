#!/usr/bin/env python3
# Ironclaw host dashboard - minimal HTTP server. Port 18795, bind 0.0.0.0.

import json
import os
import subprocess
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

DASHBOARD_DIR = os.path.dirname(os.path.abspath(__file__))
IRONCLAW_ROOT = os.path.dirname(DASHBOARD_DIR)
SCRIPTS_DIR = os.path.join(DASHBOARD_DIR, "scripts")
STATIC_DIR = os.path.join(DASHBOARD_DIR, "static")
PORT = int(os.environ.get("IRONCLAW_DASHBOARD_PORT", "18795"))
PROBE_TIMEOUT = 15


def run_probe(script_name, env_extra=None):
    script = os.path.join(SCRIPTS_DIR, script_name)
    if not os.path.isfile(script):
        return False, "script not found"
    env = os.environ.copy()
    env["IRONCLAW_ROOT"] = IRONCLAW_ROOT
    if env_extra:
        env.update(env_extra)
    try:
        r = subprocess.run(
            [script],
            capture_output=True,
            text=True,
            timeout=PROBE_TIMEOUT,
            cwd=IRONCLAW_ROOT,
            env=env,
        )
        out = (r.stdout or "").strip()
        if r.returncode != 0:
            return False, out or r.stderr or "script failed"
        if not out:
            return False, "empty output"
        try:
            return True, json.loads(out)
        except json.JSONDecodeError:
            return False, "invalid JSON"
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except Exception as e:
        return False, str(e)


class DashboardHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path.startswith("/api/"):
            self._handle_api(path)
            return
        self._serve_static(path)

    def _serve_static(self, path):
        if path == "/":
            path = "/index.html"
        filepath = os.path.join(STATIC_DIR, path.lstrip("/"))
        abs_static = os.path.abspath(STATIC_DIR)
        abs_file = os.path.abspath(filepath)
        if ".." in path or not abs_file.startswith(abs_static):
            self._send_json(404, {"ok": False, "error": "not found"})
            return
        if not os.path.isfile(filepath):
            self._send_json(404, {"ok": False, "error": "not found"})
            return
        content_type = "text/html"
        if filepath.endswith(".css"):
            content_type = "text/css"
        elif filepath.endswith(".js"):
            content_type = "application/javascript"
        try:
            with open(filepath, "rb") as f:
                body = f.read()
        except OSError:
            self._send_json(500, {"ok": False, "error": "read error"})
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle_api(self, path):
        qs = parse_qs(urlparse(self.path).query)
        agent = (qs.get("agent") or ["pibot"])[0]
        n = (qs.get("n") or ["50"])[0]

        if path == "/api/agents":
            ok, data = run_probe("probe-agents.sh")
        elif path == "/api/bridges":
            ok, data = run_probe("probe-bridges.sh")
        elif path == "/api/gateway":
            ok, data = run_probe("probe-gateway.sh", {"AGENT_NAME": agent})
        elif path == "/api/docker":
            ok, data = run_probe("probe-docker.sh")
        elif path == "/api/logs":
            ok, data = run_probe("probe-logs.sh", {"AGENT_NAME": agent, "N": n})
        elif path == "/api/failures":
            ok, data = run_probe("probe-failures.sh", {"AGENT_NAME": agent})
        elif path == "/api/usage":
            ok, data = run_probe("probe-usage.sh", {"AGENT_NAME": agent})
        elif path == "/api/channels":
            ok, data = run_probe("probe-channels.sh", {"AGENT_NAME": agent})
        elif path == "/api/rfid":
            ok, data = run_probe("probe-rfid.sh", {"AGENT_NAME": agent})
        elif path == "/api/learning":
            ok, data = run_probe("probe-learning.sh", {"AGENT_NAME": agent})
        else:
            self._send_json(404, {"ok": False, "error": "unknown endpoint"})
            return

        if ok:
            self._send_json(200, data)
        else:
            self._send_json(200, {"ok": False, "error": str(data)})

    def _send_json(self, status, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


def main():
    os.chdir(IRONCLAW_ROOT)
    if not os.path.isdir(STATIC_DIR):
        print("Static dir not found: " + STATIC_DIR, file=sys.stderr)
        sys.exit(1)
    server = HTTPServer(("0.0.0.0", PORT), DashboardHandler)
    print("Ironclaw dashboard on http://0.0.0.0:" + str(PORT), file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
