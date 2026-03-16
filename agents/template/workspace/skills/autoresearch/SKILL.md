# Autoresearch Skill

The `autoresearch` skill provides an autonomous experiment loop for your agent. You can use it to optimize your own system prompts, refine hardware-in-the-loop performance, or any other measurable goal.

## Philosophy

"Try an idea, measure it, keep what works, discard what doesn't, repeat forever."

This skill allows you to:
1.  **Initialize** a research session with a goal and primary metric.
2.  **Run** timed experiments (via shell commands).
3.  **Log** results to a persistent `autoresearch.jsonl` file.
4.  **Auto-Manage** changes: 'keep' status automatically commits changes to git, while 'discard' or 'crash' reverts them.

## Best Practices

*   **Metric-Driven**: Always define a clear, numerical primary metric (e.g., `val_bpb`, `latency_ms`, `accuracy_rate`).
*   **Git Integration**: This skill assumes you are working within a git repository. It will use git to manage your experiment versions.
*   **Stateless Awareness**: Read the `autoresearch.md` and `autoresearch.jsonl` files at the start of every session to understand what has already been tried.
*   **Hardware Control**: Use this to tune Pi-specific parameters (e.g., RFID sensitivity, audio volume, LED patterns).

## Usage

The skill provides the `autoresearch` script with three subcommands: `init`, `run`, and `log`.

### 1. Initialize Experiment
```bash
./workspace/skills/autoresearch/autoresearch.js init --name "Optimize RFID Latency" --metric "ms" --direction "lower"
```

### 2. Run Experiment
```bash
./workspace/skills/autoresearch/autoresearch.js run --command "python3 ./workspace/scripts/test-rfid.py"
```

### 3. Log Result
```bash
./workspace/skills/autoresearch/autoresearch.js log --status "keep" --metric 42 --description "Reduced poll interval to 50ms"
```

## Dashboard Integration
Your progress is automatically tracked and will appear on the IronClaw Host Dashboard under the "Research Factory" section.
