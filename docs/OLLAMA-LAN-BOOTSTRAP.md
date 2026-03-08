# Ollama on LAN — bootstrap and best-known list

When IronClaw runs with no commercial API key (or `IRONCLAW_OLLAMA_FIRST=1`), it discovers Ollama servers on the LAN at compose-up, patches config-runtime with a local primary and fallbacks, and maintains a **best-known** list in the agent workspace. The agent is instructed to use this list so local models stay the default.

---

## Skill–model mapping

| Skill / use        | Model type         | Source / notes                                                                 |
|--------------------|--------------------|--------------------------------------------------------------------------------|
| Gateway chat/tools | Text, tool-capable | `openclaw.json` primary/fallbacks (from discovery or ollama-best-known). Prefer: qwen3, qwen2.5-coder, llama3.2; not DeepSeek-R1. |
| image-vision       | Vision             | `llama3.2-vision:latest` (script); uses OLLAMA_HOST + ollama-hosts.json.       |
| image-gen          | Image generation   | flux2-klein / z-image-turbo from catalog; optional DALL-E if API key set.    |
| Heartbeat          | Lightweight text   | Set to local primary when in Ollama-first mode to avoid cloud cost.           |

---

## Recommended first pull on the LAN Ollama host

To avoid disk exhaustion, **do not** pull every model. On the machine where Ollama runs:

- **One small text model** for chat/tools: e.g. `ollama pull llama3.2:latest` or `ollama pull qwen3:8b`
- **Optional:** `ollama pull llama3.2-vision:latest` for image description (image-vision skill)
- **Image-gen** only if needed (e.g. flux2-klein); these are large.

IronClaw does **not** run `ollama pull` from the Pi or container; recommendations only.

---

## workspace/ollama-best-known.json

The agent’s workspace holds a single canonical file: **`workspace/ollama-best-known.json`**. It lists recently discovered and **verified** Ollama hosts and their models (quality scrutiny: each host is probed with a minimal completion before being marked “known good”).

### Schema

```json
{
  "updated_at": "2026-03-08T12:00:00Z",
  "hosts": [
    {
      "host": "192.168.1.10",
      "port": 11434,
      "last_probed_at": "2026-03-08T12:00:00Z",
      "last_success_at": "2026-03-08T12:00:05Z",
      "text_models": ["ollama/llama3.2:latest", "ollama/qwen3:8b"],
      "vision_models": ["ollama/llama3.2-vision:latest"],
      "image_models": ["ollama/flux2-klein:latest"]
    }
  ],
  "recommended_primary": "ollama/llama3.2:latest",
  "recommended_fallbacks": ["ollama/qwen3:8b"],
  "source_host": "192.168.1.10"
}
```

- **last_probed_at:** When discovery last ran for this host.
- **last_success_at:** When a minimal completion last succeeded for this host (null until verified).
- **recommended_primary / recommended_fallbacks:** Tool-capable models from the chosen host; the agent and (at compose-up) config-runtime use these.

### Bootstrap at compose-up

When `compose-up.sh` runs and `OLLAMA_HOST` is unset, it runs `discover-ollama.sh`, picks a LAN host, and:

1. Patches `config-runtime/openclaw.json` (baseUrl, and when Ollama-first: primary, fallbacks, heartbeat.model).
2. Writes the initial `workspace/ollama-best-known.json` from the discovery catalog (last_success_at is null until the first refresh).

### Refresh script (required verification)

**`scripts/refresh-ollama-best-known.sh`** re-runs discovery and **verifies each host** with a minimal `POST /api/generate` (one token). Only hosts that return HTTP 200 get a non-null `last_success_at`. Then it recomputes recommended_primary and recommended_fallbacks and writes the file back.

Usage:

```bash
./scripts/refresh-ollama-best-known.sh <agent-name>
```

Run it on the **same schedule as the agent heartbeat** (e.g. every 2h) so the list stays “known good.”

### Cron (2h, same as heartbeat)

Example (run as the Pi user or the user that owns the repo):

```bash
0 */2 * * * cd /path/to/ironclaw && ./scripts/refresh-ollama-best-known.sh sample-agent
```

`setup-raspberry-pi.sh` optionally installs this cron for the sample-agent so Pi deployments keep the list updated without manual steps.

---

## Agent use

- **HEARTBEAT.md** tells the agent: if `workspace/ollama-best-known.json` exists, prefer its `recommended_primary` and `recommended_fallbacks` for local inference and when suggesting model switches or reporting capabilities.
- **AGENTS.md** states: for local inference, prefer the hosts and models in `workspace/ollama-best-known.json` when present.

No OpenClaw code changes are required; the file is in the workspace so it is in the agent’s context, and the refresh runs on the same cadence as the heartbeat.

---

## See also

- [MODEL-CHOICE.md](MODEL-CHOICE.md) — tool-capable models, Qwen3 vs Qwen2.5-Coder, timeouts.
- [scripts/discover-ollama.sh](../scripts/discover-ollama.sh) — LAN scan and catalog output.
