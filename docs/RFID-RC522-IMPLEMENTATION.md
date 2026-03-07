# RFID RC522 — implementation record and maintenance

This document records **what was built**, **what code was written**, **how it works**, and **how to update and maintain** both the host daemon and the agent skill so you can make small changes or add new capabilities (e.g. via Telegram) later.

---

## 1. What this plan did

- **Host:** A Python daemon on the Raspberry Pi that polls the RC522 over SPI. On each new scan (with debouncing) it (a) writes the last scan to a JSON file in the pibot workspace, and (b) sends a Telegram message.
- **Agent:** A pibot skill **rfid-reader** that reads that JSON file when the user asks “who scanned?” or “last RFID scan?” and replies with the tag ID and time. No hardware access from the container.

---

## 2. What code was written

| Path | Purpose |
|------|---------|
| `agents/pibot/workspace/rfid/rfid_daemon.py` | Host daemon: poll RC522, debounce, write `last_scan.json`, send Telegram, **notify gateway** via `POST /hooks/agent` (with `deliver: true`, `channel: telegram`, `to: chat_id`) so the agent runs and its reply is delivered to Telegram; ensures `.watcher_state.json` exists; loads env from `agents/pibot/.env`; needs `OPENCLAW_HOOKS_TOKEN` or `OPENCLAW_GATEWAY_TOKEN`. |
| `agents/pibot/workspace/rfid/rfid_notify_bridge.py` | Host one-shot: compare `last_scan.json` to `.last_notified.json`; if new, call `POST /hooks/agent` with same deliver/channel/to (fallback when daemon notify failed). Run via `rfid-notify-bridge.timer` every 10s. |
| `scripts/systemd/rfid-notify-bridge.user.service.example` | User systemd oneshot unit for the bridge. |
| `scripts/systemd/rfid-notify-bridge.user.timer.example` | User systemd timer: every 10s. |
| `agents/pibot/workspace/rfid/requirements-rfid.txt` | Python deps on host: `mfrc522`, `RPi.GPIO`. Use a venv: `python3 -m venv .venv --system-site-packages` then `.venv/bin/pip install mfrc522`. |
| `agents/pibot/workspace/rfid/test_rfid_telegram.py` | One-off test: init RC522, try read_no_block a few times, send a Telegram message (run with `.venv/bin/python3`). |
| `agents/pibot/workspace/skills/rfid-reader/SKILL.md` | Skill definition: when to use, pipeline (read file → respond), no jq. |
| `agents/pibot/workspace/skills/rfid-reader/scripts/format-last-scan.sh` | Optional formatter: read `last_scan.json` with Python, print one-line summary; used by skill or agent. |
| `agents/pibot/workspace/rfid/scan_watcher.py` | **Generic** script (no instance data): reads `last_scan.json` and optional `card_names.json`, prints one line (dog-tracking or generic) for the bot to send. Run by the agent on RFID hook. |
| `agents/pibot/workspace/rfid/card_names.json` | **Instance config:** tag_id/uid_hex → display name; optional `_timezone`, `_dog_tracking_names`, `_dog_tracking_message`. See `workspace/rfid/README.md`. |
| `agents/pibot/workspace/rfid/card_names.json.example` | Example card config; copy to `card_names.json` and edit per instance. |
| `agents/pibot/workspace/rfid/README.md` | Describes `card_names.json` format and reserved keys. |
| `agents/pibot/.env.example` | (No change for RFID; daemon uses existing TELEGRAM_BOT_TOKEN and allowFrom from config.) |
| `.gitignore` | Added `agents/*/workspace/rfid/last_scan.json` and `agents/*/workspace/rfid/scans.jsonl`. |
| `agents/pibot/workspace/TOOLS.md` | Added “RFID reader” section: skill usage and host daemon pointer. |
| `agents/pibot/workspace/AGENTS.md` | Added “RFID reader” section: use rfid-reader skill for who/last scan. |
| `docs/RFID-RC522-PIBOT.md` | Setup: wiring, SPI, deps, env, how to run daemon (manual + systemd), skill usage. |
| `scripts/systemd/rfid-daemon.user.service.example` | Example systemd user unit for the RFID daemon; copy to `~/.config/systemd/user/rfid-daemon.service`. |
| `docs/RFID-RC522-IMPLEMENTATION.md` | This file: implementation record and maintenance. |

**Runtime artifact (not committed):** `agents/pibot/workspace/rfid/last_scan.json` — written by the daemon, read by the skill.

---

## 3. How it works

- **Data flow**
  - RC522 (SPI) → **rfid_daemon.py** (runs on Pi host).
  - Daemon on new scan: (1) writes `last_scan.json` under `agents/pibot/workspace/rfid/`, (2) sends one Telegram message (debounce ~3 s), (3) calls the OpenClaw gateway `POST /hooks/agent` with `deliver: true`, `channel: "telegram"`, and `to: <chat_id>` so the **agent runs and its reply is delivered to Telegram** (dog-tracking acknowledgment).
  - Optional **rfid_notify_bridge.py** (host): run every 10s via systemd timer; if `last_scan.json` is newer than last notified, calls `/hooks/agent` with the same payload. Fallback so the agent is notified even if the daemon’s immediate call failed.
  - Container mounts `agents/pibot/workspace` as `workspace`; so the agent sees `workspace/rfid/last_scan.json`. The daemon ensures `.watcher_state.json` exists (empty `{}` if missing) so in-container readers never get ENOENT.
  - When the user asks “who scanned?” etc., the agent uses the **rfid-reader** skill: read that file, then reply with tag_id and timestamp (or “no recent scan” if missing).

- **Who runs where**
  - **Host:** `rfid_daemon.py` only. Needs SPI, GPIO, and `TELEGRAM_*` in env (or in `agents/pibot/.env`).
  - **Container:** OpenClaw agent; skill only reads the shared file. No GPIO/SPI in the container.

- **Identifier:** Daemon uses stored text from the tag if present, else UID in hex (`tag_id`). Same as the erg-room project.

---

## 4. How to update and maintain — host side

- **Where the daemon lives:** `agents/pibot/workspace/rfid/rfid_daemon.py`
- **Edit behavior:** Change message text, debounce window (`debounce_seconds`), or add env vars in the script; load them from `.env` or systemd `EnvironmentFile`.
- **Run/restart:** Manual: `python3 agents/pibot/workspace/rfid/rfid_daemon.py` from repo root. Systemd: `systemctl --user restart rfid-daemon.service` (see `docs/RFID-RC522-PIBOT.md` for the unit).
- **Secrets:** `TELEGRAM_BOT_TOKEN` and `OPENCLAW_HOOKS_TOKEN` (or `OPENCLAW_GATEWAY_TOKEN`) from `agents/pibot/.env`. Chat ID from `config/openclaw.json` → `channels.telegram.allowFrom`. Gateway must have `hooks.enabled: true` and `hooks.token` (e.g. `${OPENCLAW_HOOKS_TOKEN}`) in `openclaw.json`. Do not commit `.env`.
- **Adding host-side behavior:** e.g. log every scan to `scans.jsonl`, or call another API: add logic in `rfid_daemon.py` after writing `last_scan.json` and (if needed) add new env vars. Keep writing `last_scan.json` so the skill still works.
- **Why not rely on in-container cron for RFID:** OpenClaw’s cron tool stores jobs in config-runtime; they can be lost on container restart when config is re-synced. The host daemon + optional notify bridge give immediate and fallback notification without depending on cron inside the container.

---

## 5. How to update and maintain — agent side

- **Where the skill lives:** `agents/pibot/workspace/skills/rfid-reader/`  
  - `SKILL.md` — when to use, pipeline steps.  
  - `scripts/format-last-scan.sh` — optional one-line summary (Python for JSON, no jq).

- **Change when the skill triggers:** Edit the “When to use” / description in `SKILL.md` so the LLM routes the right user phrases to this skill.

- **Change the reply:** Adjust the pipeline in `SKILL.md` (e.g. add a step) or change `format-last-scan.sh` output. Agent can also just `read` the JSON and format in-context.

- **Card names and dog-tracking (per instance):** Edit `workspace/rfid/card_names.json`. Keys are tag_id or uid_hex (normalized: lowercase, spaces→underscores); values are display names. Optional: `_timezone` (e.g. `America/Los_Angeles`), `_dog_tracking_names` (list of display names that get the special message), `_dog_tracking_message` (template with `{card_name}` and `{time}`). If the file is missing, scan_watcher uses no mappings and UTC. See `workspace/rfid/README.md`.

- **Add new capabilities via Telegram:**  
  - New **commands or intents** (e.g. “/lastscan” or “list recent scans”): add a new skill or extend this skill’s pipeline; if you need more state, have the daemon write it (e.g. `scans.jsonl` or `recent.json`) under `workspace/rfid/` and read it from the skill.  
  - New **Telegram notifications** (e.g. only for certain tag IDs): change the daemon to check `tag_id` or use a mapping under `workspace/rfid/` before calling the Telegram API.

- **Consistency:** New skills: `bash /home/ai_sandbox/.openclaw/workspace/scripts/create-skill.sh <name>`. Document any new tools in `agents/pibot/workspace/TOOLS.md` and behavior in `AGENTS.md`.

---

## 6. Quick reference

- **Wiring / SPI / run daemon:** [RFID-RC522-PIBOT.md](RFID-RC522-PIBOT.md)  
- **This file:** what was done, file list, how it works, how to maintain and extend host + agent.
