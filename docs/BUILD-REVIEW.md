# IronClaw build review — file-by-file and next steps

## Plan status

| Item | Status | Notes |
|------|--------|------|
| Phase 1: Healthcheck | Done | TCP check in docker-compose.yml |
| Phase 1: Log rotation | Done | json-file max-size 10m, max-file 3 |
| Phase 1: Config permissions | Done | Documented in README |
| Workspace + logs dirs | Done | .gitkeep added; README chown steps |
| Doc/SOP (README) | Done | SOP-001, SOP-002, permissions, known issues |
| Phase 2: Telegram token verify | Pending | Confirm env → openclaw.json if needed |
| Phase 2: Latency baseline | Pending | Time to first token vs webhook timeout |
| Email Loop (Gmail/heartbeat) | Pending | Cron + safe-tools-only |
| Tools block (SOP-003) | Deferred | Schema doesn’t support agents.defaults.tools in this image |
| Phase 3: Stateless/tmpfs | Future | Optional hardening |

---

## File-by-file review (10 changes)

### Modified — keep and commit

1. **`.gitignore`**  
   - Added: `.env`, `.env.*`, `!.env.example` (secrets).  
   - Added: `!logs/.gitkeep` so the logs dir is tracked; `logs/*` and `logs/gateway.*.lock` stay ignored.  
   - Added: `config/agents/main/sessions/`, `config/cron/*.bak`, `config/update-check.json` (runtime state).  
   - Correct: do not commit secrets or runtime logs/state.

2. **`docker-compose.yml`**  
   - Healthcheck: TCP connect to 127.0.0.1:18789 (Node one-liner), 30s interval, 10s timeout, 3 retries, 15s start_period.  
   - Logging: `json-file`, max-size 10m, max-file 3.  
   - Volumes: config (rw), workspace, logs, logs→openclaw-1000.  
   - Command: `["gateway"]`.  
   - Correct as-is.

3. **`README.md`**  
   - SOP-001 (SSH, tunnel, no HTTP UI note, secrets).  
   - SOP-002 (Nuke Protocol, health).  
   - Config/volume permissions (UID 1000, chmod 750).  
   - Known issues, resource summary.  
   - Correct; add to repo.

### Modified — do not commit (runtime)

4. **`logs/gateway.8654b9eb.lock`**  
   - Runtime lock file. Already covered by `logs/*` and `logs/gateway.*.lock`. If it’s still tracked, run:  
     `git rm --cached logs/gateway.8654b9eb.lock logs/openclaw-2026-02-11.log`  
   - Then leave them untracked (gitignore applies).

5. **`logs/openclaw-2026-02-11.log`**  
   - Runtime log. Same as above: `git rm --cached` if tracked, then do not commit.

### Untracked — add to repo

6. **`README.md`** — Add and commit.  
7. **`logs/.gitkeep`** — Add and commit (keeps logs dir in repo).  
8. **`workspace/.gitkeep`** — Add and commit (keeps workspace dir in repo).  
9. **`scripts/tunnel-diagnose.sh`** — Add and commit (diagnostic script for tunnel debugging).

### Untracked — do not add (runtime or backup)

10. **`config/agents/main/sessions/`** — Session state. Now in .gitignore; do not add.  
11. **`config/cron/jobs.json.bak`** — Backup. Now in .gitignore; do not add.  
12. **`config/workspace/`** — Gateway-created content under config. Optional: add `config/workspace/` to .gitignore if you don’t want to track it; otherwise leave untracked and do not add.

### Not in the “10 changes” but important

- **`config/openclaw.json`** — If tracked: ensure it has no real secrets (use placeholders; real values from .env). Current placeholders: `REPLACE_WITH_KEY`, `REPLACE_WITH_SECURE_TOKEN`. Correct for a template.

---

## What to do with the 10 changes

**Commit these:**

- `.gitignore`
- `docker-compose.yml`
- `README.md`
- `logs/.gitkeep`
- `workspace/.gitkeep`
- `scripts/tunnel-diagnose.sh`

**Stop tracking (if they are tracked), do not commit:**

- `logs/gateway.8654b9eb.lock`
- `logs/openclaw-2026-02-11.log`

```bash
git rm --cached logs/gateway.8654b9eb.lock logs/openclaw-2026-02-11.log 2>/dev/null || true
```

**Do not add:**

- `config/agents/main/sessions/`
- `config/cron/jobs.json.bak`
- `config/workspace/` (unless you explicitly want it under version control)

---

## How to test

Run on the **Intel Mac** (macbookpro.lan):

1. **Stack and health**  
   ```bash
   cd ~/openclaw_jail
   docker compose up -d
   docker ps   # expect (healthy) for openclaw_secure
   docker logs openclaw_secure 2>&1 | tail -20
   ```

2. **Ollama reachable**  
   On the host: `curl -s http://127.0.0.1:11434/api/tags` (or ensure Ollama is listening on 0.0.0.0 and `lsof -i :11434`).

3. **Gateway listening**  
   On the Intel Mac: `lsof -i :18789` (process listening on 127.0.0.1:18789).

4. **Tunnel from local Mac**  
   On your local machine:  
   `ssh -f -N -L 18790:127.0.0.1:18789 <your-user>@<your-host>.lan`  
   Then: `curl -s -w "%{http_code}" -o /dev/null http://127.0.0.1:18790/`  
   Expect: connection works (empty reply or 000 is OK; connection refused = tunnel or gateway down).

5. **CLI/TUI**  
   On Intel Mac:  
   `docker compose exec -it openclaw_secure openclaw tui`  
   (or `openclaw status` / `openclaw dashboard` to see what the image supports.)

6. **Telegram** (when configured)  
   Send a message to the bot; confirm it receives and responds (after fixing 401 if the token was placeholder).

---

## What to do next (development)

1. **Phase 2 — Telegram**  
   Put a real `TELEGRAM_BOT_TOKEN` in `.env` and ensure the plugin in `openclaw.json` uses it (or references env). Fix 401 and run a loopback test (send message, get reply).

2. **Phase 2 — Latency**  
   Send a simple prompt via Telegram (or TUI); measure time to first token. If it’s close to or over the webhook timeout, tune timeout or model.

3. **Email Loop (Section 6)**  
   Configure Gmail (IMAP/SMTP or OpenClaw Gmail integration) for the heartbeat account; add a cron job (e.g. every 10–20 min) that runs the HEARTBEAT loop; restrict to safe tools and reply by email.

4. **Optional**  
   Revisit tools/approvals if you upgrade the image and the schema supports `agents.defaults.tools` or the documented exec/browser/fs “ask” pattern.  
   Later: Phase 3 tmpfs/stateless config if you want stricter immutability.

---

## One-line summary

Phase 1 and docs are done; commit the six files above and untrack the two logs; test with the checklist; then move on to Phase 2 (Telegram + latency) and the Email Loop.
