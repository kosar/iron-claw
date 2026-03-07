#!/usr/bin/env python3
"""
Host-side iMessage attachment sender service.

Listens on port 18799 for image POST requests from Docker containers
and sends them via osascript/Messages.app. Files are staged in
~/Library/Messages/Attachments/bb/ — imagent (the iMessage daemon) uploads
attachments to MMCS from here. /tmp does NOT work; imagent can't access it.
Requires Full Disk Access for the python3 binary (or Terminal if running manually).

Start: python3 scripts/imessage-sender.py
Or as a LaunchAgent: run scripts/setup-imessage-sender.sh
"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import os, subprocess, urllib.parse, time, sys, threading

ATTACH_DIR = os.path.expanduser("~/Library/Messages/Attachments/bb")
TMP_DIR = "/tmp/imessage-sender"
PORT = 18799
SECRET = (os.environ.get("IMESSAGE_SENDER_SECRET") or "").strip()
if not SECRET:
    print("IMESSAGE_SENDER_SECRET is required. Set it in the environment and restart.", file=sys.stderr)
    sys.exit(1)


def send_via_applescript(phone: str, filepath: str, caption: str = "") -> tuple[bool, str]:
    """Send an image (and optional caption) via iMessage using AppleScript.

    phone can be either a phone number (+14251234567) or a chat GUID
    (any;+;abc123 for group chats, any;-;+14251234567 for DMs by GUID).
    """
    safe_path = filepath.replace('"', "")
    safe_caption = caption.replace("\\", "\\\\").replace('"', '\\"') if caption else ""

    # Group/DM GUIDs contain semicolons — send to chat object by iterating chats
    is_guid = ";" in phone

    if is_guid:
        safe_guid = phone.replace('"', "").replace("\\", "")
        script = f"""tell application "Messages"
    set targetChat to missing value
    repeat with c in every chat
        if id of c = "{safe_guid}" then
            set targetChat to c
            exit repeat
        end if
    end repeat
    if targetChat is missing value then
        error "Chat not found: {safe_guid}"
    end if
    send (POSIX file "{safe_path}") to targetChat
end tell"""
        cap_script = f"""tell application "Messages"
    set targetChat to missing value
    repeat with c in every chat
        if id of c = "{safe_guid}" then
            set targetChat to c
            exit repeat
        end if
    end repeat
    if targetChat is not missing value then
        send "{safe_caption}" to targetChat
    end if
end tell""" if caption else ""
    else:
        safe_phone = phone.replace('"', "")
        script = f"""tell application "Messages"
    set s to first service whose service type = iMessage
    set theBuddy to buddy "{safe_phone}" of s
    send (POSIX file "{safe_path}") to theBuddy
end tell"""
        cap_script = f"""tell application "Messages"
    set s to first service whose service type = iMessage
    set theBuddy to buddy "{safe_phone}" of s
    send "{safe_caption}" to theBuddy
end tell""" if caption else ""

    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=20)
    if result.returncode != 0:
        return False, result.stderr.strip()

    if cap_script:
        subprocess.run(["osascript", "-e", cap_script], timeout=15)

    return True, ""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"status":"ok","service":"imessage-sender"}')
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/send-imessage":
            self.send_response(404)
            self.end_headers()
            return

        params = dict(urllib.parse.parse_qsl(parsed.query))

        if not SECRET or params.get("password") != SECRET:
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b'{"error":"unauthorized"}')
            return

        phone = params.get("phone", "").strip()
        ext = params.get("ext", "jpg").strip().lstrip(".")
        caption = urllib.parse.unquote(params.get("caption", ""))

        if not phone:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'{"error":"missing phone"}')
            return

        if ext not in ("jpg", "jpeg", "png", "gif", "webp", "heic", "mp4", "mov"):
            ext = "jpg"

        length = int(self.headers.get("Content-Length", 0))
        if not length:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'{"error":"no image data"}')
            return

        image_data = self.rfile.read(length)

        filename = f"bb-{int(time.time())}-{os.getpid()}.{ext}"

        # Write to /tmp first (no FDA needed), then use Finder to copy into
        # ~/Library/Messages/Attachments/bb/ — imagent can only upload from there.
        # Finder has FDA so this works without granting FDA to python3.
        os.makedirs(TMP_DIR, exist_ok=True)
        tmp_path = os.path.join(TMP_DIR, filename)
        with open(tmp_path, "wb") as f:
            f.write(image_data)
        os.chmod(tmp_path, 0o644)

        # Use Finder (which has Full Disk Access) to copy into the Messages attachments dir
        # We use a generous timeout because Finder can be slow.
        attach_dir_abs = ATTACH_DIR
        finder_copy = subprocess.run(
            ["osascript", "-e",
             f'tell application "Finder" to duplicate (POSIX file "{tmp_path}") '
             f'to (POSIX file "{attach_dir_abs}") with replacing'],
            capture_output=True, text=True, timeout=60
        )
        if finder_copy.returncode != 0:
            os.unlink(tmp_path)
            self.send_response(500)
            self.end_headers()
            self.wfile.write(f'{{"error":"Finder copy failed: {finder_copy.stderr.strip()}"}}'.encode())
            return

        filepath = os.path.join(ATTACH_DIR, filename)
        time.sleep(2)  # Short pause to let filesystem sync

        ok, err = send_via_applescript(phone, filepath, caption)

        # Delay cleanup — imagent uploads the attachment asynchronously after osascript queues it.
        # Deleting immediately causes error=25 (MMCS upload failure). Give it 90 seconds.
        def deferred_delete(paths, delay=90):
            time.sleep(delay)
            for p in paths:
                try:
                    os.unlink(p)
                except OSError:
                    pass
        threading.Thread(target=deferred_delete, args=([filepath, tmp_path],), daemon=True).start()

        if ok:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(f'{{"error":"{err}"}}'.encode())

    def log_message(self, format, *args):
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        print(f"[{ts}] {format % args}", flush=True)


if __name__ == "__main__":
    os.makedirs(TMP_DIR, exist_ok=True)
    print(f"iMessage sender service starting on port {PORT}", flush=True)
    print(f"Staging: {TMP_DIR} → {ATTACH_DIR} (via Finder)", flush=True)
    try:
        server = HTTPServer(("0.0.0.0", PORT), Handler)
        server.serve_forever()
    except KeyboardInterrupt:
        print("Stopped.", flush=True)
        sys.exit(0)
