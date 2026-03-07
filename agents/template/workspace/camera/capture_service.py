#!/usr/bin/env python3
"""
USB camera capture service for pibot. Runs on the Raspberry Pi host.
Listens for HTTP requests; on /capture captures one frame from the first
available /dev/video* and writes to workspace/camera/latest.jpg (so the
container sees it via the shared mount). Does not send to Telegram — the
agent does that via send-photo.sh.

Port: 18792 by default. Override with env CAPTURE_PORT (e.g. in .env or systemd).
"""

import json
import os
import subprocess
import sys

# Port for the capture HTTP server. Change here or set CAPTURE_PORT in env.
DEFAULT_PORT = 18792

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LATEST_PATH = os.path.join(SCRIPT_DIR, "latest.jpg")
KNOWLEDGE_PATH = os.path.join(SCRIPT_DIR, "camera-knowledge.md")


def list_video_devices():
    """Return list of /dev/video* devices that exist."""
    out = []
    for i in range(8):
        p = f"/dev/video{i}"
        if os.path.exists(p):
            out.append(p)
    return sorted(out)


def capture_first_device():
    """Capture one frame from first available /dev/video* using ffmpeg. Return (ok, error_msg)."""
    devices = list_video_devices()
    if not devices:
        return False, "no /dev/video* devices found"
    device = devices[0]
    os.makedirs(SCRIPT_DIR, exist_ok=True)
    tmp = os.path.join(SCRIPT_DIR, "_capture_tmp.jpg")  # .jpg so image2 muxer accepts it
    # Brighten: eq brightness -1.0..1.0 (positive = brighter), contrast ~0..3 (1 = normal)
    brightness = float(os.environ.get("CAMERA_BRIGHTNESS", "0.5"))
    contrast = float(os.environ.get("CAMERA_CONTRAST", "1.08"))
    vf = f"eq=brightness={brightness}:contrast={contrast}"
    cmd = [
        "ffmpeg", "-y", "-f", "v4l2", "-i", device,
        "-vf", vf,
        "-frames:v", "1", "-q:v", "2", "-update", "1",  # high quality JPEG, single file
        tmp,
    ]
    try:
        subprocess.run(cmd, capture_output=True, timeout=15)
        if os.path.isfile(tmp):
            os.replace(tmp, LATEST_PATH)
        else:
            return False, "ffmpeg did not produce output"
    except subprocess.TimeoutExpired:
        return False, "ffmpeg timeout"
    except FileNotFoundError:
        return False, "ffmpeg not installed"
    except Exception as e:
        return False, str(e)
    if len(devices) > 1:
        write_device_knowledge(devices, device)
    return True, None


def write_device_knowledge(devices, used):
    """Write that we detected multiple devices; we use the first. Agent can read this."""
    with open(KNOWLEDGE_PATH, "w") as f:
        f.write(f"# USB camera devices\n\n")
        f.write(f"Detected {len(devices)} USB video device(s): {', '.join(devices)}\n\n")
        f.write(f"Using first device for captures: **{used}**\n")
        f.write(f"Other devices available for future use.\n")


def main():
    port = int(os.environ.get("CAPTURE_PORT", DEFAULT_PORT))
    try:
        from http.server import HTTPServer, BaseHTTPRequestHandler
    except ImportError:
        print("Python http.server required", file=sys.stderr)
        sys.exit(1)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.rstrip("/") == "/capture":
                self._capture()
            else:
                self.send_response(404)
                self.end_headers()

        def do_POST(self):
            if self.path.rstrip("/") == "/capture":
                self._capture()
            else:
                self.send_response(404)
                self.end_headers()

        def _capture(self):
            ok, err = capture_first_device()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            if ok:
                body = json.dumps({"ok": True, "path": "workspace/camera/latest.jpg"})
            else:
                body = json.dumps({"ok": False, "error": err})
                print(f"Capture failed: {err}", file=sys.stderr)
            self.wfile.write(body.encode())

        def log_message(self, format, *args):
            pass  # quiet

    # Bind to all interfaces so container (host.docker.internal) can reach us
    server = HTTPServer(("0.0.0.0", port), Handler)
    print(f"Capture service on 0.0.0.0:{port} (override with CAPTURE_PORT)", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
