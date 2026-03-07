#!/usr/bin/env bash
# send-email.sh — Send email via Gmail SMTP using curl
# Usage: send-email.sh <to> <subject> <body-file>
# Reads SMTP config from environment variables.
#
# Required env vars:
#   SMTP_FROM_EMAIL  — sender address (e.g., you@gmail.com)
#   GMAIL_APP_PASSWORD — Google app password for SMTP auth
#
# The body-file should be a plain text file. If "-" is passed, reads from stdin.

set -e

TO="${1:?Usage: send-email.sh <to> <subject> <body-file>}"
SUBJECT="${2:?Usage: send-email.sh <to> <subject> <body-file>}"
BODY_FILE="${3:?Usage: send-email.sh <to> <subject> <body-file>}"

FROM="${SMTP_FROM_EMAIL:?SMTP_FROM_EMAIL not set}"
PASSWORD="${GMAIL_APP_PASSWORD:?GMAIL_APP_PASSWORD not set}"

# Build RFC 2822 message
MSG_FILE=$(mktemp)
trap 'rm -f "$MSG_FILE"' EXIT

cat > "$MSG_FILE" <<EOF
From: ${FROM}
To: ${TO}
Subject: ${SUBJECT}
Date: $(date -R 2>/dev/null || date)
Content-Type: text/plain; charset=UTF-8

EOF

if [[ "$BODY_FILE" == "-" ]]; then
  cat >> "$MSG_FILE"
else
  cat "$BODY_FILE" >> "$MSG_FILE"
fi

# Send via Gmail SMTP (TLS on port 465)
curl --silent --show-error \
  --url "smtps://smtp.gmail.com:465" \
  --mail-from "$FROM" \
  --mail-rcpt "$TO" \
  --upload-file "$MSG_FILE" \
  --user "${FROM}:${PASSWORD}" \
  --ssl-reqd
