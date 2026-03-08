# Image Generation

Generate images from text descriptions and send them to the user.
Uses local Ollama servers on the LAN with automatic cloud fallback.

## Pipeline

### Step 1: Generate the image

Call the **exec** tool with these MANDATORY parameters:

```json
{
  "command": "bash /home/openclaw/.openclaw/workspace/skills/image-gen/scripts/generate-image.sh \"your detailed prompt\"",
  "yieldMs": 120000,
  "timeout": 300
}
```

**MANDATORY exec parameters:**
- `yieldMs: 120000` — wait up to 2 minutes for the image before backgrounding. Without this, the command backgrounds after 10 seconds and you lose the result.
- `timeout: 300` — hard kill after 5 minutes.
- Do NOT pass a file path argument — the script generates a unique filename automatically.

The script prints one of these lines to stdout:
- `OK:local:<model>:<host>:<path>` — generated locally via Ollama on LAN
- `OK:provider:<path>` — generated via cloud provider
- `OK:dalle:<path>` — generated via OpenAI DALL-E
- `UNAVAILABLE:...` — no image gen available

**CRITICAL:** The `<path>` at the end of the `OK:` line is the actual file. You MUST extract this path and use it in step 2. Every request produces a different path. Never reuse or guess a path.

### Step 2: Send the image to the user

Extract the file path from step 1's output (the last colon-separated field), then send it:

```json
{
  "command": "bash /home/openclaw/.openclaw/workspace/scripts/send-photo.sh <path-from-step-1> \"your caption here\"",
  "timeout": 30
}
```

**Caption rules:**
- Use plain text only — NO HTML tags (they show as raw text in Telegram)
- Keep it short: describe what was generated
- Example: `A watercolor golden retriever in a garden`

### Step 3: Reply with context

After sending the photo, reply with a brief text message. Do NOT include the file path or technical details. Just acknowledge the image naturally:
- "Here you go — a watercolor golden retriever in a garden."
- "Done! Let me know if you'd like adjustments."

**IMPORTANT:** Always send the photo BEFORE your text reply. The photo must arrive first.

## Handling backgrounded image generation

If step 1 returns a "Command still running" message instead of an OK line, the image is generating in the background. Tell the user you're working on it. When a system event arrives with `Exec completed` containing an `OK:` line and a path, immediately:
1. Extract the path from the completion message
2. Run send-photo.sh with that path (step 2 above)
3. Tell the user the image is ready

## If generation fails

If the script returns `UNAVAILABLE`, tell the user image generation isn't available right now. Do NOT mention tool names, file paths, or technical details.

## Re-scanning the LAN for Ollama servers

To refresh the list of known Ollama hosts:

    bash /home/openclaw/.openclaw/workspace/skills/image-gen/scripts/discover-ollama.sh /home/openclaw/.openclaw/workspace/skills/image-gen/ollama-hosts.json

## Prompt tips

- Be specific: "a watercolor painting of a golden retriever in a garden" > "dog"
- For logos/text: "minimalist logo for a coffee shop called 'Brew', black on white"
- For photorealistic: "professional product photo of red sneakers on white background"

## Fallback chain (automatic, handled by the script)

1. **Stored last host** — if we used a local Ollama recently, try that host and model first (skips re-scan).
2. Known Ollama hosts from catalog (LAN), using each host’s image models from the catalog.
3. Re-scan LAN if known hosts are down; then retry with catalog.
4. host.docker.internal (Docker bridge to host).
5. **Optional pull** — if no host has an image model, try pulling `x/flux2-klein` on the host, then generate.
6. Provider’s image model (if configured via env).
7. OpenAI DALL-E (if OPENAI_API_KEY is set) — used only when no local Ollama image model is available.
8. Graceful unavailable message.

The script logs the source to stderr (`IMAGE_GEN_SOURCE=local` or `dalle` or `provider`) so logs show whether the image was generated locally or via a commercial API.

**Do not call the Ollama API directly.** Always use the script.
