# RFID workspace data (pibot)

This directory is used by the RFID daemon (host) and the **scan_watcher** script (container) for card scans and naming.

## Files

| File | Purpose |
|------|---------|
| `last_scan.json` | Written by the daemon on each scan (tag_id, uid_hex, timestamp_iso). Not committed. |
| `card_names.json` | **Card mapping and options.** Maps tag_id / uid_hex → display name. Optional keys (reserved): `_timezone`, `_dog_tracking_names`, `_dog_tracking_message`, `_card_sounds`. See below. |
| `card_names.json.example` | Example config; copy to `card_names.json` and edit for your instance. |
| `.watcher_state.json` | Last-notified state for scan_watcher. Not committed. |

## card_names.json format

- **Card mappings:** Any key that does not start with `_` is a tag identifier (tag_id or uid_hex). The value is the display name shown in the bot’s reply.  
  Tag IDs are matched after normalizing (lowercase, spaces → underscores), so `"White key card"` and `"white_key_card"` can both map to the same name.

- **Optional config (keys starting with `_`):**
  - `_timezone` — IANA timezone for scan times (e.g. `America/Los_Angeles`). Default: UTC if missing.
  - `_dog_tracking_names` — List of display names that get the special “dog tracking” message instead of the generic line.
  - `_dog_tracking_message` — Template for that message. Use placeholders `{card_name}` and `{time}`.
  - `_card_sounds` — Optional map of **display name** → WAV filename (e.g. `"Lucy love card": "woof.wav"`). When a scanned card resolves to that display name, the daemon plays that file from this directory (if it exists). If the card is not in the map or the file is missing, the daemon plays the default two-tone latch. Use `woof.wav` for a generated small-dog woof (daemon creates it if missing).

Example:

```json
{
  "_timezone": "America/Los_Angeles",
  "_dog_tracking_names": ["Lucy love card"],
  "_dog_tracking_message": "🐾 {card_name} scanned at {time} — someone took care of Lucy!",
  "_card_sounds": { "Lucy love card": "woof.wav" },
  "white_key_card": "Lucy love card",
  "a3df6c0515": "Lucy love card"
}
```

If `card_names.json` is missing, scan_watcher uses no mappings (all cards show as “Card &lt;tag_id&gt;”), UTC, and the generic “📛 … scanned at …” line.
