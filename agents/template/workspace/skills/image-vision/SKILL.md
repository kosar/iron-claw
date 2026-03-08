# Image vision (describe image)

Describe or answer questions about an image using the LAN Ollama vision model (llama3.2-vision:latest). Use when the user sends a photo and asks what's in it, or to describe/analyze an image.

**Gateway integration:** The pibot gateway runs this skill's `describe-image.sh` as the first `tools.media.image` entry (CLI type) so inbound photos are described by local Ollama before the reply model sees them. Fallback is OpenAI gpt-4o if the CLI fails.

## Pipeline

### Step 1: Get the image path

When the user sends a photo with a message like "what's in this?" or "describe this image", the message may include an attachment. Use the path the gateway provides (e.g. from the message or a downloaded file under workspace). If the gateway gives a URL, download it to workspace first and use that path (Rule 6b: files passed between tools must be under workspace).

### Step 2: Run the describe script via exec

```json
{
  "command": "bash /home/openclaw/.openclaw/workspace/skills/image-vision/scripts/describe-image.sh \"<path-to-image>\" \"<optional-question>\"",
  "timeout": 150
}
```

- **path-to-image:** Full path to the image file (workspace path, e.g. under workspace/ or a path from the channel).
- **optional-question:** Default is "Describe this image." You can pass "What is in this image?", "What text is visible?", "Summarize this in one sentence.", etc.

The script prints the model's description to stdout, or `UNAVAILABLE:...` to stderr and exits non-zero if no Ollama vision host is reachable.

### Step 3: Reply with the description

Use the script output as the basis for your reply. Do not mention the script, Ollama, or file paths. If the script returns UNAVAILABLE, say vision isn't available right now (no technical details).

## Discovery

The script uses the same LAN discovery as image-gen: OLLAMA_HOST (set at compose-up for pibot), then last-used host, then ollama-hosts.json, then re-scan via discover-ollama.sh, then host.docker.internal. Ensure `llama3.2-vision:latest` is installed on your LAN Ollama: `ollama pull llama3.2-vision:latest`.

## Bins

Use `bins: ["bash", "python3", "node"]` in skill config if required. No jq.
