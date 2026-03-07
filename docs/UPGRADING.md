# Upgrading ironclaw image and OpenClaw

This document describes how to upgrade the ironclaw Docker image and/or OpenClaw for all agents.

## Overview

- **Agent state** lives in `config-runtime/` (and optionally in host `workspace/`). It is **preserved** across restarts and image upgrades unless you use `--fresh`.
- Upgrading means: rebuild the image, then recreate each agent’s container so it uses the new image. No need to wipe state.

## Steps

### 1. Rebuild the Docker image

From the repo root:

```bash
docker build -t ironclaw:2.0 .
```

Use the same tag your `docker-compose.yml` / compose template expects (e.g. `ironclaw:2.0`). See the Dockerfile and `scripts/docker-compose.yml.tmpl` for the image name in use.

### 2. Roll out to all agents

**Option A — one command (recommended):**

```bash
./scripts/rollout-image.sh
```

This rebuilds the image and then runs `./scripts/compose-up.sh <agent-name> -d` for every agent (same list as `./scripts/list-agents.sh`). Each agent is recreated with the new image; state in `config-runtime/` is kept.

**Option B — manual:**

1. Rebuild as above.
2. Restart each agent:

   ```bash
   ./scripts/compose-up.sh sample-agent -d
   ./scripts/compose-up.sh mybot -d
   # ... or use compose-up-all to start all agents:
   ./scripts/compose-up-all.sh
   ```

`compose-up-all.sh` starts all agents (or a subset if you pass names). Any already-running agent will be recreated when you run `compose-up.sh` for it, so they will use the current image.

### 3. Verify

- Check status: `./scripts/list-agents.sh`
- Test gateway: `./scripts/test-gateway-http.sh <agent-name>`
- Test a channel (e.g. send a message via Telegram) if you use one.

## Caveats

- **OpenClaw config schema:** New OpenClaw versions may add or change keys in `openclaw.json`. If the gateway logs schema warnings or fails to start after an upgrade, check release notes and adjust `agents/<name>/config/openclaw.json` (and the template under `agents/template/`) as needed. Do not add custom keys that are not in the official schema.
- **Breaking changes in the image:** Node version, OpenClaw version, or system dependencies in the Dockerfile may change behavior. Review the Dockerfile and OpenClaw changelog when upgrading.
- **State:** Using `./scripts/compose-up.sh <agent> --fresh -d` **resets** `config-runtime/` from `config/` and drops container-written state (e.g. sessions, `models.json`). Use `--fresh` only when you intend to reset state; normal upgrades do not require it.

## Summary

| Goal                         | Command / note                                      |
|-----------------------------|-----------------------------------------------------|
| Rebuild image               | `docker build -t ironclaw:2.0 .`                     |
| Roll out image to all       | `./scripts/rollout-image.sh`                         |
| Restart one agent           | `./scripts/compose-up.sh <agent-name> -d`            |
| Start all agents            | `./scripts/compose-up-all.sh`                        |
| Reset agent state (optional)| `./scripts/compose-up.sh <agent-name> --fresh -d`   |
