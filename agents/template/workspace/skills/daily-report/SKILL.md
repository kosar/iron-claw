# Daily Report Skill

Generate comprehensive daily activity reports for IronClaw agents.

## Overview

This skill creates detailed daily reports showing:
- **Cost & token usage** with model breakdowns
- **Tool usage statistics** (exec, browser, web_fetch, read, write, etc.)
- **Session activity** counts
- **Channel activity** (Telegram, BlueBubbles, WhatsApp, Webchat)
- **Errors & warnings** (when log files are available)
- **Historical trends** via metrics.jsonl

## Files

```
skills/daily-report/
├── SKILL.md              # This file
├── daily-report.py       # Working Python report generator ⭐
├── lib.sh               # Shell utilities (for bash version)
├── daily-report.sh      # Bash version (incomplete - needs jq)
└── setup-daily-report.sh # macOS LaunchAgent setup (for bash version)
```

## Usage (Python Version - Recommended)

### Generate report for yesterday
```bash
python3 skills/daily-report/daily-report.py main
```

### Generate report for specific date
```bash
python3 skills/daily-report/daily-report.py main --date 2026-02-17
```

### Save report to file
```bash
python3 skills/daily-report/daily-report.py main --save
```

### Generate for all agents
```bash
python3 skills/daily-report/daily-report.py --all
```

## Output

When using `--save`:
- **Report**: `agents/{name}/logs/reports/YYYY-MM-DD.txt`
- **Metrics**: `agents/{name}/logs/reports/metrics.jsonl` (for trend analysis)

## Example Output

```
════════════════════════════════════════════════════
  IRONCLAW DAILY REPORT  •  main  •  2026-02-18
════════════════════════════════════════════════════
Generated: 2026-02-18 21:18:33  |  Period: 2026-02-18

ACTIVITY OVERVIEW
────────────────────────────────────────────────────
Total runs:           0
Errors:               0
Warnings:             0

COST & TOKENS
────────────────────────────────────────────────────
Total cost:           $0.9965
  Input tokens:       1,029,986
  Output tokens:      20,436
  Turns counted:      111

Model breakdown:
  moonshot/kimi-k2.5             106 turns
  openai/gpt-5-nano              3 turns

TOOL USAGE
────────────────────────────────────────────────────
  exec                   48 calls
  read                   6 calls
  web_fetch              6 calls
  browser                5 calls
  write                  4 calls
```

## Requirements

- **Python 3.6+** (tested with 3.11)
- No external Python packages needed (uses stdlib only)

## Data Sources

The report reads from:
- **Session files**: `agents/{name}/sessions/*.jsonl` — for cost, tokens, tool calls
- **Log files**: `agents/{name}/logs/openclaw-YYYY-MM-DD.log` — for run counts, errors (optional)

## Notes

- The Python version works without `jq` and is recommended for container environments
- The bash version (`daily-report.sh`) was the original implementation but requires `jq` which may not be available in all containers
- Cost tracking requires sessions with usage metadata (OpenClaw stores this automatically)
- The "runs" count currently requires log files which may not be present in all setups
