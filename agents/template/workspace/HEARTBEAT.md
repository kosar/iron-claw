# Heartbeat — Memory Maintenance

On each heartbeat cycle, perform lightweight memory maintenance. Most cycles should complete with no action (reply HEARTBEAT_OK). Only do real work when conditions are met.

## Step 0: Check onboarding TODO

If `workspace/TODO.md` exists and contains `## [ ]` entries:
1. Read it and work through tasks you can complete autonomously (verify keys, test endpoints, check files)
2. Mark completed tasks as `## [x]`
3. Compile status: what you completed, what needs human input, overall progress
4. If the owner has given you instructions or orders in chat to work on specific TODO items, execute those — you are authorized to do legwork on behalf of the owner to close out onboarding
5. Compile status: what you completed, what needs human input, overall progress
6. Log status to `workspace/onboarding-log.md` (always — include timestamp)
7. **Email throttle:** Only email the admin if ONE of these is true:
   - You completed a task this cycle (real progress worth reporting)
   - All tasks are now done (completion notice)
   - It has been **24 hours or more** since the last onboarding email (check `workspace/onboarding-log.md` for the last `[emailed]` entry)
   - This is the very first heartbeat with TODO.md present (initial status)
8. If emailing: use `bash /home/openclaw/.openclaw/workspace/scripts/send-email.sh` and log `[emailed]` with timestamp to onboarding-log.md
9. If email fails, log the failure to onboarding-log.md and continue — never surface to chat
10. If all tasks are done: write final summary to onboarding-log.md, email the owner a completion notice, rename TODO.md → TODO.done.md
11. Do NOT mention onboarding in any chat channel response

Then proceed to normal heartbeat steps below.

## Step 1: Check memory directory

List files in `workspace/memory/`. If the directory doesn't exist, create it.

Look for today's daily notes file: `workspace/memory/daily-YYYY-MM-DD.md` (use today's date).

- If it **doesn't exist**, create it with a header: `# Daily Notes — YYYY-MM-DD` and an empty body. Then reply HEARTBEAT_OK.
- If it **already exists**, proceed to Step 2.

## Step 2: Check if MEMORY.md needs curation

Read `workspace/MEMORY.md`. Check the `last_curated` date at the bottom of the file.

- If `last_curated` is **less than 3 days ago** (or missing and there are fewer than 3 daily notes files), reply HEARTBEAT_OK — no curation needed yet.
- If `last_curated` is **3 or more days ago** (or missing and there are 3+ daily notes), proceed to Step 3.

## Step 3: Curate MEMORY.md

1. Read all daily notes files from the last 5 days (`workspace/memory/daily-*.md`).
2. Extract significant items: decisions made, problems solved, user preferences learned, important events.
3. Update `workspace/MEMORY.md`:
   - Add new distilled entries under appropriate sections
   - Remove or update entries that are now outdated
   - Update `last_curated: YYYY-MM-DD` at the bottom
4. Delete daily notes files older than 7 days.
5. Reply with a brief summary of what was curated.

## Guidelines

- **Local models:** If `workspace/ollama-best-known.json` exists, prefer its `recommended_primary` and `recommended_fallbacks` for local inference. When suggesting model switches or reporting capabilities, use this list as the source of best-known LAN options.
- **Be conservative**: Skip curation if daily notes are sparse or trivial (e.g., only heartbeat entries).
- **Keep MEMORY.md concise**: Each entry should be 1-2 lines. Group by topic, not by date.
- **Don't duplicate AGENTS.md content**: MEMORY.md is for learned knowledge, not static instructions.
- **Daily notes format**: When the agent learns something notable during normal conversations, it should append to today's daily notes file. Heartbeat just curates — it doesn't generate new knowledge.
