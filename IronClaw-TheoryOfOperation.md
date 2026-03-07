# IronClaw Theory of Operation

Technical reference for how IronClaw wraps OpenClaw: what we use, what we constrain, and how the system works end-to-end. Intended for senior technical review.

---

## 1. Scope and Context

**IronClaw** is a factory and operational wrapper for running **OpenClaw** agent gateways in Docker. Each agent is one container: one OpenClaw gateway process, one port, one set of config and workspace. We do not modify OpenClaw's code. We:

- Build a single image from the official OpenClaw installer; the container runs `openclaw gateway`.
- Provide a config sync and compose pipeline so the container never mounts or writes to the host's source config.
- Harden the container (read-only root fs, no capabilities, non-root, resource limits).
- Enforce exec and sandbox policy per agent so exec works without Docker inside the container where we don't have it.
- Inject port, exec host, and sandbox mode on every start so runtime config cannot drift from policy.

**Target environments:** Intel Mac (e.g. 32GB), Raspberry Pi (ARM64). Same Dockerfile; image is built per architecture. Agent count and resource limits are per-agent via `agent.conf`.

---

## 2. OpenClaw: What It Is and What We Use

OpenClaw is the runtime inside the container. We use it as a black box with a fixed interface:

- **Entrypoint:** `openclaw gateway`. Config is read from `~/.openclaw` (we mount that from host-prepared config-runtime).
- **Config:** JSON under `~/.openclaw/openclaw.json` (and other files under `~/.openclaw`). OpenClaw validates schema; we do not add custom keys it doesn't understand.
- **Tools:** exec, read, write, edit, web_fetch, browser, memory_search, sessions, cron, message, etc. We enable/disable via config; we do not change tool implementations.
- **Channels:** Telegram, HTTP, etc. We configure tokens and allowlists via config and `.env`; we do not change channel code.
- **Skills:** OpenClaw discovers skills under `workspace/skills/{name}/` (SKILL.md + scripts). We add skills by placing them in the host workspace; they are visible in the container via the workspace mount.

We **do not** upgrade or patch OpenClaw from inside the container. The image is built at image-build time; the root filesystem is read-only. Upgrading means rebuilding the image and redeploying.

**OpenClaw behaviour we rely on:**

- Gateway binds to a configurable host/port; we set `gateway.bind: "lan"` and `gateway.port` so the process listens on the right interface for Docker port mapping.
- Exec tool supports `host`: `gateway` (run in gateway process), `node` (separate node host), or `sandbox` (OpenClaw spawns a separate Docker container to run the command). We use `gateway` for agents that run in our Docker container so we do not require Docker inside the container.
- Sandbox mode (`agents.defaults.sandbox.mode`) controls whether tools run "in sandbox" (Docker) or "on host" (gateway process). We set `mode: "off"` for pibot so no sandbox runtime is required.
- Config and workspace paths: OpenClaw reads from `~/.openclaw`; we control what is in that tree via mounts and sync.

---

## 3. IronClaw: What We Add and What We Constrain

### 3.1 Config / Runtime Split

The host holds the source of truth:

- `agents/{name}/config/` — OpenClaw config (openclaw.json, agents/, etc.). **The container never mounts this and never writes to it.**
- `agents/{name}/workspace/` — Agent personality, skills, scripts. Host is source; the container sees it via a dedicated mount (see 3.2).
- `agents/{name}/.env` — Secrets. Gitignored; loaded by Docker into the container as env.

At start we build a **runtime** view:

- `agents/{name}/config-runtime/` — Copy/sync of `config/` with specific exclusions so we keep sessions, memory DB, and other container-written state. The **container mounts only config-runtime** at `/home/ai_sandbox/.openclaw`. So from the container's perspective, "config" is whatever is in config-runtime. We own that directory; we repopulate it from `config/` on every `compose-up` (except excluded paths).

**Constraint:** The container has no way to overwrite `config/`. It can write only to config-runtime (which we can resync) and to the mounted workspace and logs. A bad run cannot corrupt the canonical config on the host.

### 3.2 Volume Layout and What the Container Sees

Compose is run from `agents/{name}/`. The generated `docker-compose.yml` (from `scripts/docker-compose.yml.tmpl` via envsubst) mounts:

| Host path (relative to agent dir) | Container path | Writable by container |
|-----------------------------------|----------------|------------------------|
| `./config-runtime`                | `/home/ai_sandbox/.openclaw` | Yes (sessions, memory, browser state, etc.) |
| `./workspace`                     | `/home/ai_sandbox/.openclaw/workspace` | Yes |
| `./logs`                          | `/tmp/openclaw` and `/tmp/openclaw-1000` | Yes |

The **workspace** mount is a separate bind mount that overlays the `workspace` subtree of the first mount. So the container's view of `.openclaw/workspace` is **always** the host's `agents/{name}/workspace/`. Any file we write under the host's `agents/{name}/workspace/` (e.g. `workspace/skills/send-email/.env`) is visible inside the container at `.openclaw/workspace/...`. The container never sees `config-runtime/workspace/` at runtime because the workspace mount takes precedence.

The container never sees `config/` at all.

### 3.3 Sync and Inject (compose-up.sh)

Before every `docker compose up`, `scripts/compose-up.sh` runs with the agent name as first argument. It sources `scripts/lib.sh` and calls `resolve_agent` so `AGENT_DIR`, `AGENT_CONFIG`, `AGENT_CONFIG_RUNTIME`, `AGENT_WORKSPACE`, `AGENT_PORT`, etc. are set.

**Sync phase:**

1. **config → config-runtime**
   - If `--fresh`: remove config-runtime, copy config entirely. Optionally preserve `config-runtime/devices` so pairing state survives.
   - Else: if config-runtime missing, copy config once; else rsync `config/` → `config-runtime/` with exclusions:
     - `agents/main/sessions` (persist conversation state)
     - `agents/main/agent/models.json` (container-written pricing)
     - `devices/` (pairing)
     - `memory/main.sqlite` (memory DB)
     - `update-check.json`, `telegram/update-offset-*.json`
   So sessions and container-written state persist across restarts; the rest is refreshed from config.

2. **Host AGENTS.md** — Prepend host `workspace/AGENTS.md` into `config-runtime/workspace/AGENTS.md` (with marker and separator). Because the container mounts host workspace at `.openclaw/workspace`, the container reads the host's `workspace/AGENTS.md`; the merged file in config-runtime is for consistency when config-runtime is used as the source (e.g. full copy). Skills and scripts are rsynced from host `workspace/skills/` and `workspace/scripts/` into `config-runtime/workspace/`; with the overlay, the container sees the host workspace directly, so the live view of skills and scripts is from the host.

3. **Send-email credentials** — If `agents/{name}/.env` exists and `agents/{name}/workspace/skills/send-email/` exists, extract lines matching `SMTP_FROM_EMAIL` and `GMAIL_APP_PASSWORD` from `.env` and write them to `agents/{name}/workspace/skills/send-email/.env`. So the send-email script (which may run in an exec context that doesn't inherit Docker env) can read credentials from that file. This file is gitignored.

**Inject phase (jq into config-runtime/openclaw.json):**

- Set `gateway.port` to the agent's port (from `agent.conf`).
- **For pibot:** Set `agents.defaults.sandbox.mode` to `"off"` and `tools.exec.host` to `"gateway"`. Set `tools.exec.security` to `"full"` and `tools.exec.ask` to `"off"`.
- **For other agents:** Set `tools.exec.host` to `"sandbox"`, same security and ask.

So every start re-applies policy. Even if someone or something edited config-runtime/openclaw.json, the next compose-up restores the intended exec host and sandbox mode.

**Other steps:** Chrome lock cleanup in config-runtime, log dir creation and chown when run as root (pibot on Pi), session prune, session heal (strip broken reasoning state), then envsubst to generate `docker-compose.yml` from the template. For pibot only: discover Ollama on the LAN and set `OLLAMA_HOST` for the container. Then `docker compose -p {name} -f {agent_dir}/docker-compose.yml up ...`.

---

## 4. Exec and Sandbox: OpenClaw vs Our Constraint

### 4.1 OpenClaw's Exec Model

OpenClaw's exec tool can run a shell command in three contexts:

- **gateway** — Same process (or same host) as the gateway. Command runs with the gateway's environment (env vars, cwd, filesystem). No extra isolation.
- **node** — A separate "node" host (companion process or machine). Used for distributed or dedicated exec runners. We do not use this.
- **sandbox** — OpenClaw spawns a **separate Docker container** to run the command. Requires the `docker` binary and a Docker daemon available to the gateway process. Gives strong isolation (separate filesystem, network, lifecycle) but adds the dependency on Docker.

Sandbox mode (`agents.defaults.sandbox.mode`) can be `"all"` (everything sandboxed), `"non-main"` (only non-main sessions), or `"off"` (everything runs on "host" i.e. gateway). When mode is `"off"`, no sandbox runtime is used. When `tools.exec.host` is set to `"sandbox"` and sandbox mode is on, OpenClaw will try to spawn Docker for each exec; if Docker is not available (e.g. not in PATH or daemon not reachable), exec fails with e.g. `spawn docker ENOENT` or "sandbox runtime is unavailable".

### 4.2 Our Constraint: No Docker Inside the Container

Our agent containers are built from a single Dockerfile. They run as non-root, read-only root filesystem, no Docker installed, no Docker socket mounted. So **inside** the container there is no `docker` binary and no daemon. If we set `tools.exec.host: "sandbox"`, OpenClaw tries to run something like `docker run ...` and fails. We do not want to install Docker in the container or mount the host's Docker socket because:

- Installing Docker inside the container (Docker-in-Docker) adds image size, privilege and kernel requirements, and operational complexity.
- Mounting the host's Docker socket gives the container (and thus the gateway) the ability to create and control containers on the host. That is a much larger trust boundary than "run a shell command in this container."

So we constrain: for agents that run in **our** Docker container (e.g. pibot on a Pi), we set sandbox mode off and exec host to gateway. Exec then runs in the same container as the gateway. The **container** is the isolation boundary; we do not add a second layer of containers.

### 4.3 Per-Agent Policy

- **pibot** (and any agent we run in an environment where the container has no Docker): `agents.defaults.sandbox.mode: "off"`, `tools.exec.host: "gateway"`. Injected every run by compose-up.
- **Other agents** (e.g. ironclaw-bot, stylista on a Mac where the host has Docker): we keep `tools.exec.host: "sandbox"` so that when OpenClaw runs on that host, it can use Docker for exec if the gateway is not in a container, or if in the future we run them in a way that exposes Docker. For our current layout, those agents also run inside our container, so they would hit the same "no Docker" limit; the script today only special-cases pibot by name. If we need other agents to run without Docker, we would extend the condition (e.g. by agent name or by a flag in agent.conf).

**Tradeoff:** Gateway exec means the command runs in the same process environment as the gateway. A malicious or buggy script could in theory affect the gateway (e.g. kill the process, exhaust memory). We accept this because (a) the container is already the boundary and is hardened, (b) we control the skills and the exec allowlist, and (c) we are not running arbitrary untrusted code. For multi-tenant or highly untrusted exec, we would need to revisit (e.g. dedicated exec runner or Docker-in-Docker with strict limits).

---

## 5. File Paths and Workspace Rule

Tools such as **write** and **exec** both run inside the same container when exec host is gateway. They share the same filesystem view. However, if the agent used **write** to create a file in `/tmp` and then passed that path to **exec**, we previously hit failures in practice: OpenClaw's write tool may write to a path that is not the same as the exec process's `/tmp` (e.g. if there were any sandbox or subprocess isolation), or the path may not be visible. To avoid that class of bug we enforce a single rule:

**Any file that the agent creates (e.g. via write) and then passes to an exec command, or any path that one exec produces and a later exec must read, must live under the workspace** — i.e. under `/home/ai_sandbox/.openclaw/workspace/...`, which is the mounted host workspace. Both the write tool and the exec process see that mount, so the path is valid for both. We document this as Rule 6b in agent guidelines (AGENTS.md) and in skill docs (e.g. send-email: body file in workspace; image-gen: script writes output under the skill dir in workspace so the "send photo" exec can read it).

**Concrete applications:**

- Send-email: Body file must be written to a path under workspace (e.g. `workspace/email_body.txt`); the script is invoked with that path. Not `/tmp/...`.
- Image-gen: The script that generates an image writes to `$SKILL_DIR/generated-*.png` (skill dir is under workspace) and prints that path; the agent then calls send-photo with that path. Previously the script wrote to `/tmp`; we changed it so the second exec always sees the file.

---

## 6. Credentials

- **Primary:** Secrets are in `agents/{name}/.env`. Docker Compose passes them into the container via `env_file` and `environment`. The gateway process and any exec running with host=gateway normally inherit that environment.
- **Fallback for send-email:** The send-email script (Python) first checks `SMTP_FROM_EMAIL` and `GMAIL_APP_PASSWORD` in the environment. If either is missing, it reads from `workspace/skills/send-email/.env` (same directory as the skill). Compose-up writes that file from the agent's `.env` (only those two variables) so that even if the exec environment does not inherit Docker env (e.g. in some code paths), the script still works. That file is gitignored.
- We do not put secrets in config files that are committed. We do not add custom schema keys to openclaw.json for secrets; we use env and the existing OpenClaw substitution (`${VAR_NAME}`).

---

## 7. Security Hardening (Container)

All agents use the same hardening in the compose template:

- **Read-only root filesystem** — Writable only where volumes are mounted (.openclaw, .openclaw/workspace, /tmp/openclaw, and /tmp for tmpfs).
- **Capabilities** — `cap_drop: [ALL]`.
- **Privilege escalation** — `security_opt: [no-new-privileges:true]`.
- **User** — `user: "1000:1000"` (ai_sandbox). Not root.
- **tmpfs for /tmp** — Size-limited, uid/gid 1000.
- **Port** — Host mapping is `127.0.0.1:${AGENT_PORT}:${AGENT_PORT}` so the gateway is only reachable on the host's loopback unless the operator changes it.
- **Init** — `init: true` (tini) to reap zombies (e.g. from Chromium).
- **Resources** — `mem_limit`, `cpus`, `shm_size` from `agent.conf`.

We do **not** mount the host Docker socket. We do **not** run the container privileged. The container is the single boundary; we do not rely on a second layer (sandbox containers) for our primary deployment.

---

## 8. Protected Settings (Do Not Change)

The following are load-bearing. Removing or changing them has caused production failures:

- **gateway.bind: "lan"** — Required so the gateway listens on a non-loopback address inside the container. Otherwise Docker port mapping cannot deliver traffic; TCP connects but the server returns empty. Documented in CLAUDE.md.
- **gateway.mode: "local"** — OpenClaw requires this to start the gateway.
- **Exec host and sandbox (pibot)** — Must remain gateway + sandbox off for pibot so exec works without Docker. Enforced by compose-up.

---

## 9. End-to-End Flow Summary

1. Operator edits only `config/`, `workspace/`, and `.env` on the host.
2. Operator runs `./scripts/compose-up.sh {agent} -d`.
3. compose-up syncs config → config-runtime (with exclusions), merges AGENTS.md, rsyncs skills/scripts into config-runtime/workspace, writes send-email `.env` into host workspace, injects port and exec/sandbox into config-runtime/openclaw.json, prunes/heals sessions, generates docker-compose.yml, runs docker compose up.
4. Container starts with config-runtime at .openclaw, host workspace at .openclaw/workspace, logs at /tmp/openclaw. Env from .env. Gateway process starts, reads openclaw.json (with our injected port and exec host).
5. Incoming requests (e.g. Telegram) hit the gateway. Agent runs; tools (read, write, exec, etc.) run in the same container. Exec runs in the gateway process (for pibot). Files shared between write and exec are under workspace. Credentials from env or workspace skill .env.
6. Container never writes to host config/. Next compose-up will resync from config/ and re-inject policy.

---

## 10. Tradeoffs and Decisions (Summary)

| Decision | Rationale | Alternative considered |
|----------|-----------|-------------------------|
| Config vs config-runtime split | Keep host config immutable; container can only affect runtime copy. Resync on every start. | Let container write to config: rejected (corruption risk). |
| Container mounts config-runtime, not config | Container never sees or touches source. | Mount config read-only: would still allow container to write elsewhere; we want a single writable config tree we control. |
| Workspace mounted separately and overlays .openclaw/workspace | Container sees host workspace directly; skills and credential files (e.g. send-email .env) are on host and visible. | Single mount of config-runtime including workspace: would require syncing workspace into config-runtime and would duplicate; overlay keeps one source (host workspace). |
| Exec host=gateway for pibot | No Docker in container; sandbox would require Docker. Gateway exec runs in same container. | Docker-in-Docker or socket mount: rejected (trust and complexity). |
| Sandbox mode off for pibot | Disables OpenClaw's sandbox runtime so exec does not try to spawn Docker. | Leave sandbox on: would cause "sandbox unavailable" / spawn docker ENOENT. |
| Inject exec host and sandbox on every compose-up | Policy lives in the script; config-runtime cannot drift. | Rely on config only: config could be edited or overwritten; we enforce on each run. |
| Workspace-only path rule for cross-tool files | Guarantees write and exec see the same path; avoids /tmp and path-mismatch bugs. | Allow /tmp: caused "file not found" and "email not configured" in practice. |
| Send-email .env in workspace | Script can read credentials when exec env doesn't inherit Docker env. Compose-up writes from agent .env. | Rely only on Docker env: failed when exec did not inherit; file fallback fixes it. |
| Port bound to 127.0.0.1 on host | Restricts who can reach the gateway; operator can change if needed. | Bind 0.0.0.0: would expose gateway to LAN without extra controls. |

---

## 11. Key File Reference

| File | Role |
|------|------|
| `scripts/lib.sh` | Exports AGENT_*, CONFIG, CONFIG_RUNTIME, WORKSPACE, etc. from agent.conf. Sourced by compose-up and other scripts. |
| `scripts/compose-up.sh` | Sync, inject, prune, heal, generate compose, up. Single entry for "start this agent." |
| `scripts/docker-compose.yml.tmpl` | Template for per-agent compose; envsubst with AGENT_*, OLLAMA_HOST, SCAN_SUBNET. |
| `agents/{name}/agent.conf` | AGENT_NAME, AGENT_PORT, AGENT_CONTAINER, AGENT_MEM_LIMIT, AGENT_CPUS, AGENT_SHM_SIZE. Sourced by lib.sh. |
| `agents/{name}/config/openclaw.json` | Source OpenClaw config. Never mounted into container. |
| `agents/{name}/config-runtime/openclaw.json` | Runtime config; we inject gateway.port, tools.exec.*, agents.defaults.sandbox.mode here. |
| `agents/{name}/.env` | Secrets; env_file in compose. Gitignored. |
| `agents/{name}/workspace/` | Host workspace; mounted at .openclaw/workspace. Skills, scripts, and e.g. send-email/.env live here. |
| `CLAUDE.md` | Project rules and protected settings; exec/sandbox policy for pibot vs others. |
| `README.md` | User-facing overview; "Separation, Boundaries, and Execution" section aligns with this document. |
