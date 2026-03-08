---
name: send-email
description: >
  Send email via Gmail (plain text, HTML, or with attachments). Use when the user
  asks to email something, send a summary by email, email a report, or deliver
  content to an email address. Requires SMTP_FROM_EMAIL and GMAIL_APP_PASSWORD in the container.
metadata:
  openclaw:
    emoji: "📧"
    requires:
      bins: ["python3"]
---

# Send Email — Gmail (plain, HTML, attachments)

Send outbound email using the workspace script. Supports **plain text**, **HTML**, and **attachments**. Credentials: set `SMTP_FROM_EMAIL` and `GMAIL_APP_PASSWORD` in the agent `.env` (they are passed into the container). The script also reads from `workspace/skills/send-email/.env` if present (e.g. if you create that file manually for exec contexts that don't inherit env).

## When to use

- "Email me the summary" / "Send this to me by email"
- "Email that report to user@example.com"
- Onboarding/heartbeat status emails (see HEARTBEAT.md)
- Any outbound delivery to an email address

## Pipeline (execute in order)

### STEP 1 — Prepare body file (must be in workspace)

Create the message body as a **file** in the **workspace** so the exec can read it. Do **not** use `/tmp` — the sandbox may not see the same path.

- **Plain text:** `write` to e.g. `workspace/email_body.txt` or `workspace/memory/tmp_email.txt` with the body content.
- **HTML:** Same, then use `--html` in Step 2.
- Use the **full path** in Step 2: `/home/openclaw/.openclaw/workspace/email_body.txt` (or whatever path you used).

### STEP 2 — Send via script

**Plain text only (no attachments):**

```bash
python3 /home/openclaw/.openclaw/workspace/skills/send-email/scripts/send_email.py "<to@email.com>" "<Subject>" "<path-to-body-file>"
```

**HTML body (no attachments):**

```bash
python3 /home/openclaw/.openclaw/workspace/skills/send-email/scripts/send_email.py "<to@email.com>" "<Subject>" "<path-to-body-file>" --html
```

**With attachments:**

```bash
python3 /home/openclaw/.openclaw/workspace/skills/send-email/scripts/send_email.py "<to@email.com>" "<Subject>" "<path-to-body-file>" [--html] --attach <file1> [file2 ...]
```

- Replace `<to@email.com>`, `<Subject>`, and `<path-to-body-file>` with real values.
- **Body file path:** Must be a path the exec can read — use a file you created with `write` **in the workspace** (e.g. `/home/openclaw/.openclaw/workspace/email_body.txt`). Do not use `/tmp/...` as the sandbox may not see it. Use `--html` only if the body file is HTML.
- Attachments are optional; list one or more file paths after `--attach`.

### STEP 3 — Reply

- **Success:** Confirm briefly (e.g. "Done, emailed that to you."). Do not mention the script or env vars.
- **Failure:** If the script exits non-zero or prints an error, say email couldn't be sent right now. Do not expose SMTP or env details to the user. Log failure to onboarding-log.md if in a heartbeat/onboarding context (per HEARTBEAT.md).

## Capabilities (what you can say)

| Capability   | Supported |
|-------------|-----------|
| Plain text  | Yes       |
| Rich HTML   | Yes (use `--html`) |
| Attachments | Yes (use `--attach file1 [file2 ...]`) |

## Rules

- Never mention the script path, SMTP, or "Gmail" in the user-facing reply.
- Recipient comes from the user ("email me at x@y.com") or from USER.md / TODO (admin/owner email).
- Exec runs in the sandbox; no user approval is required.

## If the agent says it cannot run the script

1. **Exec host:** If the container has no Docker, set `EXEC_HOST=gateway` in `agent.conf` and run `./scripts/compose-up.sh <agent> -d` so exec runs in the container.
2. **Env in container:** Ensure `SMTP_FROM_EMAIL` and `GMAIL_APP_PASSWORD` are in the agent `.env`; restart after editing. Optionally create `workspace/skills/send-email/.env` with those two vars if the exec context doesn't inherit Docker env.
3. **Exec allowlist:** `config/exec-approvals.json` (or OpenClaw exec config) must allow running `python3` and the script path. Run compose-up to sync config → config-runtime after changes.
