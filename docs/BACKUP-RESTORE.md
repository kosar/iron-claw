# Backup and restore

This document describes how to back up an agent’s state and how to restore it.

## Creating a backup

**Script:** `./scripts/backup-agent.sh <agent-name> [--output-dir <dir>]`

- Creates a timestamped archive containing:
  - **config-runtime/** — full directory (sessions, memory, gateway state, etc.)
  - **logs/** — full directory (app logs, learning logs)
- Does **not** include `.env` or any secrets.
- A small **manifest** file inside the archive lists agent name, paths, and timestamp.

**Default location:** `agents/<agent-name>/backups/<agent-name>-YYYYMMDD-HHMMSS.tar.gz`

**Custom location:** use `--output-dir <dir>` to write the archive elsewhere (e.g. a shared backup volume).

Example:

```bash
./scripts/backup-agent.sh sample-agent
# → agents/sample-agent/backups/sample-agent-20250307-143022.tar.gz

./scripts/backup-agent.sh sample-agent --output-dir /backups/ironclaw
# → /backups/ironclaw/sample-agent-20250307-143022.tar.gz
```

The backup directory is created automatically if it does not exist.

## Restoring from a backup

1. **Extract the archive** into the agent directory so that `config-runtime/` and `logs/` are under `agents/<name>/` (overwriting existing contents as needed):

   ```bash
   cd agents/<agent-name>
   tar xzf /path/to/<agent-name>-YYYYMMDD-HHMMSS.tar.gz
   ```

2. **Restore `.env` manually.** Backups do not contain `.env`. Restore it from your secure storage (e.g. password manager, secrets store) into `agents/<agent-name>/.env`.

3. **Start the agent:**

   ```bash
   ./scripts/compose-up.sh <agent-name> -d
   ```

After that, the agent runs with the restored state. If you use `--fresh` in the future, config-runtime is reset from `config/` again; backups are independent of that.

## Security

- Never commit `.env` or backup archives that might contain secrets. The backup script explicitly omits `.env`.
- Store backups and any exported secrets in a secure location with access controls appropriate for your environment.
