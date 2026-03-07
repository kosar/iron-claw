# RFID → Bot reply: runbook (current instance)

Use this checklist on the Pi so the full flow works: **scan card → daemon → hook → bot runs scan_watcher → reply in Telegram**.

---

## Before you reboot (critical)

- [ ] **On the Pi, in `agents/pibot/.env`:** You have **OPENCLAW_HOOKS_TOKEN** set to a value **different** from OPENCLAW_GATEWAY_TOKEN. (`.env` is not in git — set it on the Pi. Same value = gateway will not start.)
- [ ] **RFID daemon starts after reboot:** Run `loginctl enable-linger $USER` once so user systemd runs at boot, then `systemctl --user enable rfid-daemon.service`. Otherwise start it by hand after login: `systemctl --user start rfid-daemon.service`.

---

## 1. Env and config

- [ ] **Distinct hooks token**  
  In `agents/pibot/.env` you must have **OPENCLAW_HOOKS_TOKEN** set to a value **different** from OPENCLAW_GATEWAY_TOKEN (same value = gateway refuses to start).  
  Generate one: `openssl rand -hex 32`  
  Add: `OPENCLAW_HOOKS_TOKEN=<paste that value>`

- [ ] **Card config**  
  File `agents/pibot/workspace/rfid/card_names.json` must exist and map your white key card (e.g. `"white key card"` / `"white_key_card"` / your uid_hex) to a display name. Optional: `_timezone`, `_dog_tracking_names`, `_dog_tracking_message`. See `README.md` in this folder.

- [ ] **Scan sound (optional)**  
  On each scan the daemon plays a two-tone latch sound via the Pi’s 3.5mm jack (requires `aplay`, e.g. `sudo apt install alsa-utils`). The daemon creates `workspace/rfid/scan_sound.wav` if missing. Sound plays only after the scan is persisted and Telegram is sent. To disable: set `RFID_PLAY_SOUND=0` in `agents/pibot/.env`.

---

## 2. Start/restart

```bash
cd ~/ironclaw

# Sync config and start pibot (gateway must be up for hooks)
./scripts/compose-up.sh pibot -d
```

Wait ~20 seconds for the gateway to be ready.

- [ ] **Test hook from host**  
  `./scripts/test-rfid-hook.sh`  
  You should see **HTTP 202** and a JSON `runId`. Then check Telegram for a bot reply in ~30–60s.  
  If you see **401**: hooks token wrong or same as gateway token.  
  If you see **connection reset**: gateway may still be starting; wait and retry.

```bash
# Restart RFID daemon so it uses .env (and OPENCLAW_HOOKS_TOKEN)
systemctl --user restart rfid-daemon.service
```

- [ ] **Optional: 10s fallback**  
  If the daemon’s immediate hook call sometimes fails, run the notify bridge every 10s:

```bash
# One-time setup (if not done)
mkdir -p ~/.config/systemd/user
cp ~/ironclaw/scripts/systemd/rfid-notify-bridge.user.service.example ~/.config/systemd/user/rfid-notify-bridge.service
cp ~/ironclaw/scripts/systemd/rfid-notify-bridge.user.timer.example ~/.config/systemd/user/rfid-notify-bridge.timer
# Edit paths in .service if your repo is not ~/ironclaw

systemctl --user daemon-reload
systemctl --user enable rfid-notify-bridge.timer
systemctl --user start rfid-notify-bridge.timer
```

---

## 3. Scan test

1. Scan your white key card (or any card in `card_names.json`).
2. In Telegram you should see:
   - The daemon’s raw line: e.g. `RFID scan: White key card at 2026-02-28T...`
   - Then the **bot’s reply**: e.g. `🐾 Lucy love card scanned at 8:34 PM PST — someone took care of Lucy!`
3. If you only see the daemon message and no bot reply:
   - Run `./scripts/test-rfid-hook.sh` again. If that returns 202, the hook path works; the issue may be the agent run (check `docker logs pibot_secure` and app logs under `agents/pibot/logs/`).
   - Check `agents/pibot/workspace/rfid/daemon.log` for hook errors (e.g. 401).
   - Ensure the notify-bridge timer is running if you use it: `systemctl --user list-timers | grep rfid`.

---

## 4. After a reboot

1. Wait for network and pibot (if you use `ironclaw-pibot.service` or run compose-up at boot, give it ~30–60s).
2. If the RFID daemon is enabled for your user (see “Before you reboot”), it should be running. Check: `systemctl --user status rfid-daemon.service`.
3. Optional: run `./scripts/test-rfid-hook.sh` — expect **HTTP 202**.
4. Scan the card and check Telegram for the daemon line + bot reply.

---

## 5. Quick reference

| What | Where |
|------|--------|
| Hooks token (must differ from gateway) | `agents/pibot/.env` → OPENCLAW_HOOKS_TOKEN |
| Card names and timezone | `agents/pibot/workspace/rfid/card_names.json` |
| Test hook | `./scripts/test-rfid-hook.sh` |
| Daemon log (hook failures) | `agents/pibot/workspace/rfid/daemon.log` |
| Scan sound (disable) | `RFID_PLAY_SOUND=0` in `.env` |
| Gateway logs | `docker logs pibot_secure` |
