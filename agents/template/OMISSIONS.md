# Template Omissions from Stock OpenClaw

This file tracks any OpenClaw features intentionally omitted from the ironclaw-core template for security or hardening reasons.

Each omission must document:
1. What was omitted
2. Why it was omitted
3. How to re-enable it if needed

---

**Currently: No omissions.**

The template ships with full OpenClaw defaults. All built-in tools (exec, read, write, edit, web_fetch, browser, memory_search, sessions_list, cron, image, message) are available. web_search is left as `enabled: false` (same as stock OpenClaw default — requires an API key to enable).
