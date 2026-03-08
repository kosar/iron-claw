# Model choice for IronClaw (Ollama + tools)

OpenClaw needs a model that **supports tool/function calling** (for exec, browser, etc.). “Reasoning” (chain-of-thought) and “tools” are separate: e.g. DeepSeek-R1 is reasoning but does **not** support tools in Ollama, so it cannot be used as the main agent model here.

**Ollama on LAN:** For automatic discovery, bootstrap (primary/fallbacks from discovery), and a persistent best-known list in the agent workspace, see [OLLAMA-LAN-BOOTSTRAP.md](OLLAMA-LAN-BOOTSTRAP.md).

---

## Is qwen2.5-coder good for non-coding?

**Yes, for mixed use.** Evidence:

- **Official:** Qwen2.5-Coder is code-focused but “retains general and math skills” (Qwen2.5-Coder report). Instruction-tuned variants are explicitly improved for instruction-style/chat and non-code tasks.
- **Benchmarks:** Strong on math (GSM8K/Math), solid on general knowledge (MMLU, ARC). So it’s not “coding only.”
- **Practical:** It’s **competent** for general chat and non-coding answers; it’s just not marketed as the main “general chat” model. For an agent that does both coding and everyday tasks, it’s a good default.

**Verdict:** Safe to keep **qwen2.5-coder:14b** as the primary model for both coding and general replies. You don’t have to switch unless you want something tuned more for general chat or reasoning.

---

## If you want a “general + reasoning + tools” model: pull Qwen3

**Qwen3** is the next gen after Qwen2.5: better reasoning, general chat, and tool support in one family. It’s on Ollama’s official **Tools** list.

**Suggested tags for a 32 GB Mac:**

| Model        | Size (approx) | Use case                    |
|-------------|----------------|-----------------------------|
| **qwen3:8b**  | ~5–9 GB        | Lighter; good balance       |
| **qwen3:14b** | ~9–16 GB       | Closer to your current 14b  |

**Pull and run:**

```bash
# On the Intel Mac (where Ollama runs)
ollama pull qwen3:8b
# or
ollama pull qwen3:14b
```

Then in `config/openclaw.json`, set:

- Primary: `"primary": "ollama/qwen3:8b"` (or `ollama/qwen3:14b`)
- Fallback: e.g. `"fallbacks": ["ollama/qwen2.5-coder:14b"]`

Restart or let the gateway reload config, then use the bot again.

---

## Other tools-capable models you already have

- **llama3.2:latest** – Supports tools in Ollama; good general-purpose. You can set it as primary or fallback if you prefer Llama over Qwen for chat.

---

## Ollama: “client closing the connection” / 500 after 1–5 minutes

If Ollama’s logs show **POST /v1/chat/completions** with **500** and **“aborting completion request due to client closing the connection”**, the **OpenClaw gateway** is closing the HTTP connection before Ollama (CPU) finishes. So Ollama *is* getting the request and generating; the gateway’s client timeout fires first, you get no reply, and Ollama aborts.

**What we changed in config:**

- **`agents.defaults.timeoutSeconds`: 600** in `config/openclaw.json` so the agent run is allowed up to 10 minutes. This may not increase the *HTTP* timeout to Ollama (that’s often fixed in the gateway build), but it’s correct to set.

**Workarounds that help:**

1. **Keep the model loaded (recommended)**  
   So the first token is faster and you’re less likely to hit the client timeout:
   ```bash
   # On the Mac where Ollama runs: load the model and keep it in memory
   ollama run qwen3:8b
   # Then send a short message and leave the session (model stays loaded for a while)
   ```
   Or set a long keep-alive so the model doesn’t unload (see Ollama docs for `OLLAMA_KEEP_ALIVE` or request options).

2. **Pre-warm before testing**  
   Before sending “hi” from Telegram, run one short completion from the host so the model is in RAM:
   ```bash
   curl -s http://127.0.0.1:11434/v1/chat/completions -d '{"model":"qwen3:8b","messages":[{"role":"user","content":"hi"}],"stream":false}' -o /dev/null
   ```

3. **Upstream**  
   OpenClaw does not yet expose a configurable *request* timeout for the Ollama provider. If timeouts persist, consider opening an issue/PR (e.g. “configurable Ollama request timeout”) on the OpenClaw repo.

---

## Summary

- **qwen2.5-coder:14b** is a good default for both coding and non-coding; no change required unless you want a different tradeoff.
- For a single model that’s stronger at general chat + reasoning and still has tools: **pull qwen3:8b or qwen3:14b** and set it as primary in `config/openclaw.json`.
- **DeepSeek-R1** cannot be used as the main agent model here because it does not support tools in Ollama.
