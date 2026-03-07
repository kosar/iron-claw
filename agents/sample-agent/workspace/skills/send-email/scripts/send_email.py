#!/usr/bin/env python3
"""
send_email.py — Send email via Gmail SMTP with optional HTML and attachments.
Uses env: SMTP_FROM_EMAIL, GMAIL_APP_PASSWORD. If not in env (e.g. sandbox exec),
reads from workspace skill .env: skills/send-email/.env (KEY=value lines).

Usage:
  send_email.py <to> <subject> <body-file> [--html] [--attach file1 [file2 ...]]

  body-file: path to plain text or HTML body (use --html for HTML).
  --attach: optional paths to files to attach (can repeat or list multiple).
"""
import os
import sys
import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.base import MIMEBase
from email import encoders
from pathlib import Path


def _load_env_file(env_path: Path) -> dict:
    """Parse KEY=value lines; strip quotes and export. Returns dict."""
    out = {}
    try:
        text = env_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return out
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if key.upper().startswith("EXPORT "):
            key = key[7:].strip()
        value = value.strip().strip("'\"")
        if key:
            out[key] = value
    return out


def _get_smtp_credentials() -> tuple:
    """Return (from_email, password). Prefer env; fallback to skill .env for sandbox exec."""
    from_email = os.environ.get("SMTP_FROM_EMAIL") or ""
    password = os.environ.get("GMAIL_APP_PASSWORD") or ""
    if from_email and password:
        return (from_email, password)
    # Sandbox exec may not inherit Docker env; read from workspace skill .env
    skill_dir = Path(__file__).resolve().parent.parent
    env_file = skill_dir / ".env"
    if env_file.is_file():
        parsed = _load_env_file(env_file)
        from_email = from_email or parsed.get("SMTP_FROM_EMAIL", "")
        password = password or parsed.get("GMAIL_APP_PASSWORD", "")
    return (from_email, password)


def main():
    if len(sys.argv) < 4:
        print("Usage: send_email.py <to> <subject> <body-file> [--html] [--attach file1 [file2 ...]]", file=sys.stderr)
        sys.exit(1)

    to_email = sys.argv[1]
    subject = sys.argv[2]
    body_file = sys.argv[3]
    args = sys.argv[4:]

    html = False
    attachments = []
    i = 0
    while i < len(args):
        if args[i] == "--html":
            html = True
            i += 1
        elif args[i] == "--attach":
            i += 1
            while i < len(args) and not args[i].startswith("--"):
                attachments.append(args[i])
                i += 1
        else:
            i += 1

    from_email, password = _get_smtp_credentials()
    if not from_email or not password:
        print("SMTP_FROM_EMAIL and GMAIL_APP_PASSWORD must be set (env or skills/send-email/.env)", file=sys.stderr)
        sys.exit(1)

    if body_file != "-" and not os.path.isfile(body_file):
        print(f"Body file not found: {body_file}", file=sys.stderr)
        sys.exit(1)

    if body_file == "-":
        body_content = sys.stdin.read()
    else:
        with open(body_file, "r", encoding="utf-8", errors="replace") as f:
            body_content = f.read()

    subtype = "html" if html else "plain"
    has_attachments = len(attachments) > 0

    if has_attachments:
        msg = MIMEMultipart("mixed")
        msg.attach(MIMEText(body_content, subtype, "utf-8"))
        for path in attachments:
            path = path.strip()
            if not path or not os.path.isfile(path):
                continue
            with open(path, "rb") as f:
                part = MIMEBase("application", "octet-stream")
                part.set_payload(f.read())
            encoders.encode_base64(part)
            part.add_header("Content-Disposition", f'attachment; filename="{Path(path).name}"')
            msg.attach(part)
    else:
        msg = MIMEText(body_content, subtype, "utf-8")

    msg["From"] = from_email
    msg["To"] = to_email
    msg["Subject"] = subject

    with smtplib.SMTP_SSL("smtp.gmail.com", 465) as server:
        server.login(from_email, password)
        server.send_message(msg)

    n = len([p for p in attachments if os.path.isfile(p.strip())])
    if n:
        print(f"Email sent to {to_email} with {n} attachment(s).")
    else:
        print(f"Email sent to {to_email}.")


if __name__ == "__main__":
    main()
