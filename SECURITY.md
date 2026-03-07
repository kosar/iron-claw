# Security

## No secrets in git

- **Never** commit secrets, API keys, tokens, or `.env` files. Use `.env.example` with placeholders; copy to `.env` locally (and add `.env` to `.gitignore`).
- Use placeholders in docs and examples: `@your_bot`, `+1XXXXXXXXXX`, `192.0.2.x`, `admin@example.com`, etc.
- No default passwords in code — require env vars for secrets and fail with a clear error if unset.

## If something sensitive was committed

1. **Rotate** all affected credentials immediately (OpenClaw tokens, Telegram, API keys, etc.).
2. Treat the credential as compromised; do not rely on removing it from the repo alone.
3. Optional: run a secret scanner on the **current tree** (e.g. `gitleaks` or `trufflehog` on HEAD or working directory) before adding contributors, to confirm the tree is clean.

## Reporting

If you find a secret or security issue in this repo, do not open a public issue. Rotate any exposed credentials and contact the maintainer privately.
