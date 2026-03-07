#!/usr/bin/env bash
# probe-learning.sh — Agent learning summary/recent/history (JSON) for dashboard.
# Usage: IRONCLAW_ROOT=/path AGENT_NAME=pibot ./probe-learning.sh
#
# Resilient behavior:
# - If learning feature/files are absent, returns ok=true with enabled=false.
# - Never includes original user/assistant conversation content.

set -e
ROOT="${IRONCLAW_ROOT:?IRONCLAW_ROOT required}"
AGENT="${AGENT_NAME:?AGENT_NAME required}"
LEARNING_DIR="$ROOT/agents/$AGENT/logs/learning"
TS_FILE="$LEARNING_DIR/quality-timeseries.jsonl"

python3 - "$AGENT" "$LEARNING_DIR" "$TS_FILE" << 'PY'
import glob
import json
import os
import statistics
import sys

agent = sys.argv[1]
learning_dir = sys.argv[2]
ts_file = sys.argv[3]

def safe_float(v, d=0.0):
    try:
        return float(v)
    except Exception:
        return d

def safe_int(v, d=0):
    try:
        return int(v)
    except Exception:
        return d

def load_timeseries(path):
    if not os.path.isfile(path):
        return []
    rows = []
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            rows.append({
                "timestamp": str(o.get("timestamp") or ""),
                "epoch": safe_int(o.get("epoch"), 0),
                "run_index": safe_int(o.get("run_index"), 0),
                "overall": round(safe_float(o.get("overall"), 0.0), 3),
                "reliability": round(safe_float(o.get("reliability"), 0.0), 3),
                "efficiency": round(safe_float(o.get("efficiency"), 0.0), 3),
                "hygiene": round(safe_float(o.get("hygiene"), 0.0), 3),
                "severity": str(o.get("severity") or ""),
                "short_delta": o.get("short_delta"),
                "short_direction": str(o.get("short_direction") or ""),
                "long_delta": o.get("long_delta"),
                "long_direction": str(o.get("long_direction") or ""),
                "feedback_uptake_rate": o.get("feedback_uptake_rate"),
            })
    # Keep a stable "from beginning to now" order.
    rows.sort(key=lambda x: (x.get("epoch", 0), x.get("run_index", 0)))
    return rows

def load_from_feedback_files(base_dir):
    # Backward compatibility if quality-timeseries isn't present yet.
    files = sorted(glob.glob(os.path.join(base_dir, "feedback-*.jsonl")))
    rows = []
    for path in files:
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        o = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    scores = o.get("scores") or {}
                    hist = o.get("history_signal") or {}
                    short = hist.get("short_term") or {}
                    long = hist.get("long_term") or {}
                    uptake = o.get("feedback_uptake") or {}
                    rows.append({
                        "timestamp": str(o.get("timestamp") or ""),
                        "epoch": safe_int(o.get("epoch"), 0),
                        "run_index": safe_int(o.get("run_index"), 0),
                        "overall": round(safe_float(scores.get("overall"), 0.0), 3),
                        "reliability": round(safe_float(scores.get("reliability"), 0.0), 3),
                        "efficiency": round(safe_float(scores.get("efficiency"), 0.0), 3),
                        "hygiene": round(safe_float(scores.get("hygiene"), 0.0), 3),
                        "severity": str(scores.get("severity") or ""),
                        "short_delta": short.get("delta"),
                        "short_direction": str(short.get("direction") or ""),
                        "long_delta": long.get("delta"),
                        "long_direction": str(long.get("direction") or ""),
                        "feedback_uptake_rate": uptake.get("uptake_rate"),
                    })
        except OSError:
            continue
    rows.sort(key=lambda x: (x.get("epoch", 0), x.get("run_index", 0)))
    return rows

def load_latest_feedback_text(base_dir):
    path = os.path.join(base_dir, "latest-feedback.txt")
    if not os.path.isfile(path):
        return ""
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            lines = [x.strip() for x in f.readlines() if x.strip()]
    except OSError:
        return ""
    # Return only concise system metrics lines, never conversational content.
    keep_prefix = (
        "quality_signal=",
        "history_short_delta=",
        "history_long_delta=",
        "feedback_uptake ",
    )
    picked = [ln for ln in lines if ln.startswith(keep_prefix)]
    return " | ".join(picked[:4])

def summarize(rows):
    if not rows:
        return {
            "count": 0,
            "first": None,
            "last": None,
            "avg_overall": None,
            "best_overall": None,
            "worst_overall": None,
            "delta_from_start": None,
            "direction_from_start": "flat",
            "severity_counts": {"excellent": 0, "healthy": 0, "watch": 0, "action": 0},
        }

    overall = [safe_float(r.get("overall"), 0.0) for r in rows]
    first = rows[0]
    last = rows[-1]
    delta = round(safe_float(last.get("overall"), 0.0) - safe_float(first.get("overall"), 0.0), 3)
    if delta > 0.12:
        direction = "up"
    elif delta < -0.12:
        direction = "down"
    else:
        direction = "flat"

    sev = {"excellent": 0, "healthy": 0, "watch": 0, "action": 0}
    for r in rows:
        s = str(r.get("severity") or "")
        if s in sev:
            sev[s] += 1

    return {
        "count": len(rows),
        "first": {"timestamp": first.get("timestamp"), "overall": first.get("overall"), "run_index": first.get("run_index")},
        "last": {"timestamp": last.get("timestamp"), "overall": last.get("overall"), "run_index": last.get("run_index")},
        "avg_overall": round(statistics.mean(overall), 3) if overall else None,
        "best_overall": round(max(overall), 3) if overall else None,
        "worst_overall": round(min(overall), 3) if overall else None,
        "delta_from_start": delta,
        "direction_from_start": direction,
        "severity_counts": sev,
    }

if not os.path.isdir(learning_dir):
    print(json.dumps({
        "ok": True,
        "agent": agent,
        "enabled": False,
        "reason": "learning directory not found",
        "summary": summarize([]),
        "recent": [],
        "history": [],
        "latestSignal": "",
    }))
    sys.exit(0)

rows = load_timeseries(ts_file)
if not rows:
    rows = load_from_feedback_files(learning_dir)

if not rows:
    print(json.dumps({
        "ok": True,
        "agent": agent,
        "enabled": False,
        "reason": "learning data not available yet",
        "summary": summarize([]),
        "recent": [],
        "history": [],
        "latestSignal": load_latest_feedback_text(learning_dir),
    }))
    sys.exit(0)

summary = summarize(rows)
recent = rows[-8:][::-1]  # most recent first for quick scan

print(json.dumps({
    "ok": True,
    "agent": agent,
    "enabled": True,
    "summary": summary,
    "recent": recent,
    "history": rows,  # full timeline from beginning to latest
    "latestSignal": load_latest_feedback_text(learning_dir),
}))
PY
