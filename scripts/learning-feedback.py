#!/usr/bin/env python3
"""
learning-feedback.py

Run-level internal quality feedback for IronClaw/OpenClaw agents.

This script is designed to be called after each "embedded run done" event.
It computes deterministic quality metrics, optionally runs a frugal LLM-as-judge
pass (direct provider call, not through the gateway), writes structured feedback
to agent logs, and sends an internal-only feedback copy to the owner/configurator.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import tempfile
import time
from collections import Counter, deque
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib import error as urlerror
from urllib import request as urlrequest


ROOT = Path(__file__).resolve().parent.parent
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
KV_RE = re.compile(r"([A-Za-z0-9_]+)=([^ ]+)")
EXAMPLE_EMAIL_DOMAINS = {"example.com", "example.org", "example.net"}

# Section marker for coaching upsert in AGENTS.md — OpenClaw injects AGENTS.md on every turn.
COACHING_SECTION_HEADER = "## Quality coaching (internal)"
COACHING_SECTION_INTRO = (
    "Lessons learned from run feedback. Apply these in future runs. "
    "OpenClaw injects this section into your context every turn."
)
COACHING_MAX_ITEMS = 7
COACHING_SKIP_PATTERNS = (
    "maintain this pattern",
    "no urgent corrective",
    "no corrective action",
    "collect a few more runs",
)

# USD per 1M tokens (input, output) for coaching merge LLM cost tracking.
COACHING_NANO_PRICING: Dict[str, Dict[str, Tuple[float, float]]] = {
    "openai": {
        "gpt-5-nano": (0.05, 0.40),
        "gpt-4.1-nano": (0.10, 0.40),
        "gpt-4o-mini": (0.15, 0.60),
    },
}


def now_epoch() -> int:
    return int(time.time())


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def parse_bool(text: str) -> bool:
    return str(text).strip().lower() in {"1", "true", "yes", "y", "on"}


def parse_int(value: Any, default: int = 0) -> int:
    try:
        return int(str(value).strip())
    except Exception:
        return int(default)


def parse_float(value: Any, default: float = 0.0) -> float:
    try:
        return float(str(value).strip())
    except Exception:
        return float(default)


def parse_int_env(env_map: Dict[str, str], key: str, default: int, minimum: int, maximum: int) -> int:
    value = parse_int(env_map.get(key, default), default)
    if value < minimum:
        return minimum
    if value > maximum:
        return maximum
    return value


def average(values: List[float]) -> float:
    if not values:
        return 0.0
    return float(sum(values) / len(values))


def parse_key_value_file(path: Path) -> Dict[str, str]:
    data: Dict[str, str] = {}
    if not path.exists():
        return data
    for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        data[key] = value
    return data


def resolve_agent(agent_name: str) -> Dict[str, Path]:
    agent_dir = ROOT / "agents" / agent_name
    if not agent_dir.exists():
        raise SystemExit(f"Agent not found: {agent_name}")
    return {
        "agent_dir": agent_dir,
        "agent_conf": agent_dir / "agent.conf",
        "agent_env": agent_dir / ".env",
        "agent_config": agent_dir / "config" / "openclaw.json",
        "agent_workspace": agent_dir / "workspace",
        "agent_logs": agent_dir / "logs",
    }


def parse_agent_conf(conf_path: Path) -> Dict[str, str]:
    return parse_key_value_file(conf_path)


def parse_msg_kv(msg: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
    for key, value in KV_RE.findall(msg):
        out[key] = value
    return out


def read_recent_log_entries(log_file: Path, max_lines: int) -> List[Dict[str, Any]]:
    if not log_file.exists():
        return []

    lines = deque(maxlen=max_lines)
    with log_file.open("r", encoding="utf-8", errors="ignore") as handle:
        for raw in handle:
            lines.append(raw.rstrip("\n"))

    entries: List[Dict[str, Any]] = []
    idx = 0
    for raw in lines:
        idx += 1
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError:
            continue
        msg = obj.get("1", "")
        if msg is None:
            msg = ""
        if not isinstance(msg, str):
            msg = str(msg)

        alt = obj.get("0", "")
        if alt is None:
            alt = ""
        if not isinstance(alt, str):
            alt = str(alt)

        meta = obj.get("_meta", {}) or {}
        level = str(meta.get("logLevelName", "")).upper()
        ts = str(obj.get("time", "") or meta.get("date", "") or "")
        entries.append(
            {
                "idx": idx,
                "msg": msg,
                "alt": alt,
                "level": level,
                "ts": ts,
            }
        )
    return entries


def build_event_key(run_id: str, done_msg: str, session_id: str, duration_ms: int, aborted: bool) -> str:
    if run_id:
        return f"run:{run_id}"
    payload = f"{done_msg}|{session_id}|{duration_ms}|{int(aborted)}"
    digest = hashlib.sha1(payload.encode("utf-8", errors="ignore")).hexdigest()[:16]
    return f"fallback:{digest}"


def default_state() -> Dict[str, Any]:
    return {
        "processed_keys": [],
        "total_evaluated": 0,
        "ewma_overall": None,
        "last_updated": None,
        "history_points": [],
        "feedback_uptake": {
            "improved": 0,
            "not_improved": 0,
        },
        "feedback_followups": [],
        "digest": {
            "pending": [],
            "last_sent_epoch": None,
        },
    }


def load_state(path: Path) -> Dict[str, Any]:
    data: Dict[str, Any]
    if not path.exists():
        data = default_state()
    else:
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
            data = loaded if isinstance(loaded, dict) else default_state()
        except Exception:
            data = default_state()

    base = default_state()
    base.update(data)

    if not isinstance(base.get("processed_keys"), list):
        base["processed_keys"] = []
    base["processed_keys"] = [str(x) for x in base["processed_keys"]][-5000:]

    base["total_evaluated"] = parse_int(base.get("total_evaluated", 0), 0)
    ewma = base.get("ewma_overall")
    base["ewma_overall"] = parse_float(ewma, 0.0) if ewma is not None else None

    if not isinstance(base.get("history_points"), list):
        base["history_points"] = []
    norm_hist: List[Dict[str, Any]] = []
    for point in base["history_points"][-2000:]:
        if not isinstance(point, dict):
            continue
        norm_hist.append(
            {
                "epoch": parse_int(point.get("epoch", 0), 0),
                "overall": parse_float(point.get("overall", 0.0), 0.0),
                "reliability": parse_float(point.get("reliability", 0.0), 0.0),
                "efficiency": parse_float(point.get("efficiency", 0.0), 0.0),
                "hygiene": parse_float(point.get("hygiene", 0.0), 0.0),
                "severity": str(point.get("severity", "watch")),
                "event_key": str(point.get("event_key", "")),
            }
        )
    base["history_points"] = norm_hist

    uptake = base.get("feedback_uptake")
    if not isinstance(uptake, dict):
        uptake = {}
    base["feedback_uptake"] = {
        "improved": parse_int(uptake.get("improved", 0), 0),
        "not_improved": parse_int(uptake.get("not_improved", 0), 0),
    }

    followups = base.get("feedback_followups")
    if not isinstance(followups, list):
        followups = []
    norm_followups: List[Dict[str, Any]] = []
    for item in followups[-500:]:
        if not isinstance(item, dict):
            continue
        norm_followups.append(
            {
                "event_key": str(item.get("event_key", "")),
                "run_index": parse_int(item.get("run_index", 0), 0),
                "baseline_overall": parse_float(item.get("baseline_overall", 0.0), 0.0),
                "target_delta": parse_float(item.get("target_delta", 0.35), 0.35),
                "max_wait_runs": parse_int(item.get("max_wait_runs", 5), 5),
            }
        )
    base["feedback_followups"] = norm_followups

    digest = base.get("digest")
    if not isinstance(digest, dict):
        digest = {}
    pending = digest.get("pending")
    if not isinstance(pending, list):
        pending = []
    digest["pending"] = [x for x in pending if isinstance(x, dict)][-500:]
    last_sent = digest.get("last_sent_epoch")
    digest["last_sent_epoch"] = parse_int(last_sent, 0) if last_sent is not None else None
    base["digest"] = digest

    return base


def save_state(path: Path, state: Dict[str, Any]) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(path)


def short_text(text: str, max_len: int = 140) -> str:
    text = " ".join((text or "").split())
    if len(text) <= max_len:
        return text
    return text[: max_len - 3] + "..."


def collect_run_context(
    entries: List[Dict[str, Any]],
    run_id: str,
    session_id: str,
    done_msg: str,
    duration_ms_arg: int,
    aborted_arg: bool,
) -> Dict[str, Any]:
    run_token = f"runId={run_id}" if run_id else ""
    session_token = f"sessionId={session_id}" if session_id else ""

    # Primary run-tagged entries.
    tagged: List[Dict[str, Any]] = []
    if run_token:
        tagged = [e for e in entries if run_token in e["msg"]]
    if not tagged and session_token:
        tagged = [e for e in entries if session_token in e["msg"] and "embedded run" in e["msg"]]

    start_entry = None
    done_entry = None
    for e in tagged:
        if e["msg"].startswith("embedded run start:") and start_entry is None:
            start_entry = e
        if e["msg"].startswith("embedded run done:"):
            done_entry = e

    context: List[Dict[str, Any]] = []
    if start_entry and done_entry and done_entry["idx"] >= start_entry["idx"]:
        for e in entries:
            if start_entry["idx"] <= e["idx"] <= done_entry["idx"]:
                context.append(e)
    elif tagged:
        context = tagged[-180:]
    else:
        context = entries[-180:]

    start_msg = start_entry["msg"] if start_entry else ""
    done_line_msg = done_entry["msg"] if done_entry else done_msg
    start_kv = parse_msg_kv(start_msg)
    done_kv = parse_msg_kv(done_line_msg)

    provider = start_kv.get("provider", "")
    model = start_kv.get("model", "")
    channel = start_kv.get("messageChannel", "unknown")
    thinking = start_kv.get("thinking", "")

    duration_ms = duration_ms_arg
    if duration_ms <= 0:
        try:
            duration_ms = int(done_kv.get("durationMs", "0"))
        except ValueError:
            duration_ms = 0
    if duration_ms <= 0:
        duration_ms = 0

    aborted = aborted_arg
    if done_kv.get("aborted", "").lower() in {"true", "false"}:
        aborted = done_kv.get("aborted", "").lower() == "true"

    prompt_rounds = 0
    tool_names: List[str] = []
    tool_failures = 0
    lane_errors = 0
    warn_count = 0
    error_count = 0
    notes: List[str] = []

    for e in context:
        msg = e["msg"]
        alt = e["alt"]
        level = e["level"]
        bound = False
        if run_token and run_token in msg:
            bound = True
        elif session_token and session_token in msg:
            bound = True

        if msg.startswith("embedded run prompt start:") and bound:
            prompt_rounds += 1

        if msg.startswith("embedded run tool start:") and bound:
            kv = parse_msg_kv(msg)
            tool = kv.get("tool", "")
            if tool:
                tool_names.append(tool)

        if "lane task error" in msg and bound:
            lane_errors += 1

        msg_lower = msg.lower()
        if ("[tools]" in msg_lower and "failed" in msg_lower and bound) or (
            "embedded run tool end:" in msg_lower and "error" in msg_lower and bound
        ):
            tool_failures += 1

        if level == "WARN" and (bound or not run_token):
            warn_count += 1
            if msg:
                notes.append(short_text(msg, 100))
        elif level == "ERROR" and (bound or not run_token):
            error_count += 1
            chosen = msg if msg else alt
            notes.append(short_text(chosen, 100))

    if prompt_rounds == 0 and start_entry is not None:
        # If no explicit prompt markers were found, assume at least one reasoning round.
        prompt_rounds = 1

    tool_counts = Counter(tool_names)
    return {
        "provider": provider,
        "model": model,
        "channel": channel,
        "thinking": thinking,
        "duration_ms": duration_ms,
        "aborted": aborted,
        "prompt_rounds": prompt_rounds,
        "tool_calls_total": sum(tool_counts.values()),
        "tool_counts": dict(tool_counts),
        "tool_failures": tool_failures,
        "lane_errors": lane_errors,
        "warn_count": warn_count,
        "error_count": error_count,
        "notes": notes[:4],
    }


def score_run(metrics: Dict[str, Any]) -> Dict[str, Any]:
    duration_ms = int(metrics.get("duration_ms", 0) or 0)
    aborted = bool(metrics.get("aborted", False))
    tool_calls_total = int(metrics.get("tool_calls_total", 0) or 0)
    tool_failures = int(metrics.get("tool_failures", 0) or 0)
    lane_errors = int(metrics.get("lane_errors", 0) or 0)
    warn_count = int(metrics.get("warn_count", 0) or 0)
    error_count = int(metrics.get("error_count", 0) or 0)
    prompt_rounds = int(metrics.get("prompt_rounds", 0) or 0)

    reliability = 5.0
    if aborted:
        reliability = 1.0
    reliability -= min(2.0, float(tool_failures))
    reliability -= min(1.5, float(lane_errors))
    if error_count > 0:
        reliability -= 1.0
    reliability = clamp(reliability, 0.0, 5.0)

    if duration_ms <= 8_000:
        efficiency = 5.0
    elif duration_ms <= 20_000:
        efficiency = 4.0
    elif duration_ms <= 45_000:
        efficiency = 3.0
    elif duration_ms <= 90_000:
        efficiency = 2.0
    else:
        efficiency = 1.0
    if tool_calls_total >= 8:
        efficiency -= 1.0
    if prompt_rounds >= 4:
        efficiency -= 0.5
    efficiency = clamp(efficiency, 0.0, 5.0)

    hygiene = 5.0
    hygiene -= min(2.0, float(error_count))
    hygiene -= min(1.5, float(warn_count))
    if tool_failures > 0:
        hygiene -= 1.0
    if aborted:
        hygiene -= 0.5
    hygiene = clamp(hygiene, 0.0, 5.0)

    overall = round((reliability * 0.45 + efficiency * 0.35 + hygiene * 0.20), 2)

    if overall >= 4.5:
        severity = "excellent"
    elif overall >= 3.5:
        severity = "healthy"
    elif overall >= 2.5:
        severity = "watch"
    else:
        severity = "action"

    return {
        "reliability": round(reliability, 2),
        "efficiency": round(efficiency, 2),
        "hygiene": round(hygiene, 2),
        "overall": overall,
        "severity": severity,
    }


def build_feedback_lines(metrics: Dict[str, Any], scores: Dict[str, Any]) -> Tuple[List[str], List[str]]:
    positives: List[str] = []
    improvements: List[str] = []

    aborted = bool(metrics.get("aborted", False))
    duration_ms = int(metrics.get("duration_ms", 0) or 0)
    tool_failures = int(metrics.get("tool_failures", 0) or 0)
    error_count = int(metrics.get("error_count", 0) or 0)
    warn_count = int(metrics.get("warn_count", 0) or 0)
    prompt_rounds = int(metrics.get("prompt_rounds", 0) or 0)
    tool_calls_total = int(metrics.get("tool_calls_total", 0) or 0)
    severity = str(scores.get("severity", "watch"))

    if not aborted:
        positives.append("Run completed end-to-end without abort.")
    if tool_failures == 0 and error_count == 0:
        positives.append("No tool failures or hard errors detected.")
    if duration_ms > 0 and duration_ms <= 20_000:
        positives.append("Latency stayed in a fast response band (<20s).")
    if prompt_rounds <= 2 and prompt_rounds > 0:
        positives.append("Reasoning rounds stayed concise (low re-prompt churn).")

    if aborted:
        improvements.append("Investigate abort root cause and add retry-safe fallback handling.")
    if error_count > 0 or tool_failures > 0:
        improvements.append("Reduce tool/error noise with tighter fallback and validation guards.")
    if warn_count >= 2:
        improvements.append("Trim warning volume to prevent drift into avoidable incidents.")
    if duration_ms > 45_000:
        improvements.append("Reduce response time by cutting tool fan-out and prompt rounds.")
    if tool_calls_total >= 8:
        improvements.append("Batch or simplify tool usage to lower latency/cost per run.")
    if prompt_rounds >= 4:
        improvements.append("Tighten planning to avoid excess model loops before final answer.")

    if not positives:
        positives.append("Run telemetry was captured cleanly for learning and trend tracking.")
    if not improvements:
        if severity in {"excellent", "healthy"}:
            improvements.append("Maintain this pattern; no urgent corrective action needed.")
        else:
            improvements.append("Collect a few more runs to confirm whether this dip persists.")

    return positives[:3], improvements[:3]


def extract_env_ref(value: str) -> Optional[str]:
    value = value.strip()
    if value.startswith("${") and value.endswith("}"):
        return value[2:-1]
    return None


def parse_json_file(path: Path) -> Optional[Dict[str, Any]]:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def resolve_judge_target(
    config: Dict[str, Any], env_map: Dict[str, str], conf: Optional[Dict[str, str]] = None
) -> Optional[Dict[str, str]]:
    # Prefer local gateway (proven working, no direct-API quirks).
    port = (conf or {}).get("AGENT_PORT", "")
    token = (env_map.get("OPENCLAW_GATEWAY_TOKEN", "") or "").strip()
    if port and token:
        try:
            port_num = int(str(port).strip())
            if 1 <= port_num <= 65535:
                return {
                    "provider": "gateway",
                    "model": "openclaw",
                    "endpoint": f"http://127.0.0.1:{port_num}/v1/chat/completions",
                    "api_key": token,
                    "agent_id": "main",
                }
        except (ValueError, TypeError):
            pass

    providers = (config.get("models", {}) or {}).get("providers", {}) or {}
    heartbeat_ref = (
        (config.get("agents", {}) or {})
        .get("defaults", {})
        .get("heartbeat", {})
        .get("model", "")
    )

    candidates: List[Tuple[str, str]] = []
    if isinstance(heartbeat_ref, str) and "/" in heartbeat_ref:
        p, m = heartbeat_ref.split("/", 1)
        candidates.append((p, m))
    # Fallback cheap defaults when heartbeat is unavailable.
    candidates.extend(
        [
            ("openai", "gpt-5-nano"),
            ("openai", "gpt-4o-mini"),
            ("moonshot", "kimi-k2.5"),
        ]
    )

    seen = set()
    ordered_candidates: List[Tuple[str, str]] = []
    for item in candidates:
        if item in seen:
            continue
        seen.add(item)
        ordered_candidates.append(item)

    for provider_name, model_id in ordered_candidates:
        provider_cfg = providers.get(provider_name)
        if not isinstance(provider_cfg, dict):
            continue
        if provider_name == "ollama":
            # Skip local-only provider for judge calls from host-side loop.
            continue
        base_url = str(provider_cfg.get("baseUrl", "") or "").strip()
        if not base_url:
            continue

        api_key_raw = str(provider_cfg.get("apiKey", "") or "").strip()
        env_ref = extract_env_ref(api_key_raw)
        api_key = env_map.get(env_ref, "") if env_ref else api_key_raw
        if not api_key:
            continue

        model_list = provider_cfg.get("models", [])
        if isinstance(model_list, list) and model_list:
            available = {str(x.get("id", "")) for x in model_list if isinstance(x, dict)}
            if model_id not in available:
                # Pick a likely-cheap fallback model if requested one is missing.
                preferred = [m for m in available if "nano" in m or "mini" in m]
                if preferred:
                    model_id = sorted(preferred)[0]
                elif available:
                    model_id = sorted(available)[0]

        endpoint = base_url.rstrip("/") + "/chat/completions"
        return {
            "provider": provider_name,
            "model": model_id,
            "endpoint": endpoint,
            "api_key": api_key,
        }
    return None


def resolve_coaching_target(
    config: Dict[str, Any], env_map: Dict[str, str], conf: Optional[Dict[str, str]] = None
) -> Optional[Dict[str, Any]]:
    """
    Resolve LLM target for coaching merge (semantic dedup). Prefers nano models.
    Env LEARNING_FEEDBACK_COACHING_MODEL overrides (e.g. openai/gpt-5-nano).
    Gateway first when available, then direct provider.
    """
    override = env_map.get("LEARNING_FEEDBACK_COACHING_MODEL", "").strip()
    default_model = "openai/gpt-5-nano"
    model_for_gateway = override if (override and "/" in override) else default_model
    provider_for_cost = model_for_gateway.split("/", 1)[0].lower() if "/" in model_for_gateway else "openai"

    port = (conf or {}).get("AGENT_PORT", "")
    token = (env_map.get("OPENCLAW_GATEWAY_TOKEN", "") or "").strip()
    if port and token:
        try:
            port_num = int(str(port).strip())
            if 1 <= port_num <= 65535:
                return {
                    "provider": provider_for_cost,
                    "model": model_for_gateway,
                    "endpoint": f"http://127.0.0.1:{port_num}/v1/chat/completions",
                    "api_key": token,
                    "agent_id": "main",
                }
        except (ValueError, TypeError):
            pass

    providers = (config.get("models", {}) or {}).get("providers", {}) or {}
    candidates: List[Tuple[str, str]] = []
    if override:
        candidates.append((override.split("/", 1)[0].strip().lower(), override.split("/", 1)[1].strip()))
    candidates.extend([
        ("openai", "gpt-5-nano"),
        ("openai", "gpt-4.1-nano"),
        ("openai", "gpt-4o-mini"),
    ])

    seen: set[Tuple[str, str]] = set()
    ordered: List[Tuple[str, str]] = []
    for p, m in candidates:
        if (p, m) in seen:
            continue
        seen.add((p, m))
        ordered.append((p, m))

    for provider_name, model_id in ordered:
        provider_cfg = providers.get(provider_name)
        if not isinstance(provider_cfg, dict):
            continue
        if provider_name == "ollama":
            continue
        base_url = str(provider_cfg.get("baseUrl", "") or "").strip()
        if not base_url:
            continue
        api_key_raw = str(provider_cfg.get("apiKey", "") or "").strip()
        env_ref = extract_env_ref(api_key_raw)
        api_key = env_map.get(env_ref, "") if env_ref else api_key_raw
        if not api_key:
            continue
        model_list = provider_cfg.get("models", [])
        if isinstance(model_list, list) and model_list:
            available = {str(x.get("id", "")) for x in model_list if isinstance(x, dict)}
            if model_id not in available:
                preferred = [m for m in available if "nano" in m or "mini" in m]
                model_id = sorted(preferred)[0] if preferred else (sorted(available)[0] if available else model_id)
        endpoint = base_url.rstrip("/") + "/chat/completions"
        model_for_request = model_id if provider_name != "openai" else model_id
        return {
            "provider": provider_name,
            "model": model_for_request,
            "endpoint": endpoint,
            "api_key": api_key,
        }
    return None


def call_coaching_merge_llm(
    target: Dict[str, Any],
    current_cues: List[str],
    new_cues: List[str],
) -> Tuple[bool, List[str], Dict[str, Any]]:
    """
    Use nano LLM to merge current + new coaching cues: semantic dedup, consolidate, drop stale.
    Returns (success, curated_list, usage_info).
    """
    system = (
        "You curate agent coaching cues. Given CURRENT cues (in document) and NEW cues (from run feedback), "
        "output JSON only: {\"curated\": [\"cue1\", \"cue2\", ...]}. "
        "Merge semantically similar cues into one concise phrase. Drop stale or obsolete cues. "
        "Keep up to 7 actionable bullets. Each string max 200 chars. Prefer new cues that add value. "
        "Output only valid JSON, no markdown, no explanation."
    )
    user = "CURRENT cues:\n" + json.dumps(current_cues, ensure_ascii=True) + "\n\nNEW cues:\n" + json.dumps(new_cues, ensure_ascii=True)

    payload = {
        "model": target["model"],
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": 0,
        "max_tokens": 600,
    }
    body = json.dumps(payload).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {target['api_key']}",
    }
    if target.get("agent_id"):
        headers["x-openclaw-agent-id"] = str(target["agent_id"])
    req = urlrequest.Request(
        target["endpoint"],
        data=body,
        headers=headers,
        method="POST",
    )
    usage_info: Dict[str, Any] = {}

    try:
        with urlrequest.urlopen(req, timeout=25) as resp:
            raw = resp.read().decode("utf-8", errors="ignore")
    except urlerror.URLError as exc:
        return False, [], {"error": str(exc)}
    except Exception as exc:
        return False, [], {"error": str(exc)}

    try:
        data = json.loads(raw)
    except Exception:
        return False, [], {"error": "non_json_response"}

    usage = data.get("usage") or {}
    if isinstance(usage, dict):
        usage_info["prompt_tokens"] = int(usage.get("prompt_tokens") or 0)
        usage_info["completion_tokens"] = int(usage.get("completion_tokens") or 0)
        usage_info["total_tokens"] = int(usage.get("total_tokens") or 0)

    content = (
        (data.get("choices", [{}])[0] or {})
        .get("message", {})
        .get("content", "")
    )
    obj = extract_json_object(str(content))
    if not obj or "curated" not in obj:
        return False, [], usage_info

    curated = obj.get("curated", [])
    if not isinstance(curated, list):
        return False, [], usage_info
    result = [short_text(str(x).strip(), 200) for x in curated if x]
    return True, result[:COACHING_MAX_ITEMS], usage_info


def compute_coaching_cost(provider: str, model: str, usage: Dict[str, Any]) -> float:
    """Compute USD cost from token usage using COACHING_NANO_PRICING."""
    prompt = int(usage.get("prompt_tokens") or 0)
    completion = int(usage.get("completion_tokens") or 0)
    if prompt <= 0 and completion <= 0:
        return 0.0
    model_id = model.split("/", 1)[-1].strip() if "/" in model else model
    pricing = COACHING_NANO_PRICING.get(provider, {}).get(model_id)
    if not pricing:
        return 0.0
    inp_per_m, out_per_m = pricing
    return round((prompt / 1_000_000 * inp_per_m) + (completion / 1_000_000 * out_per_m), 6)


def extract_json_object(text: str) -> Optional[Dict[str, Any]]:
    raw = (text or "").strip()
    if not raw:
        return None

    if raw.startswith("```"):
        raw = raw.strip("`")
        if raw.lower().startswith("json"):
            raw = raw[4:].strip()

    try:
        obj = json.loads(raw)
        if isinstance(obj, dict):
            return obj
    except Exception:
        pass

    match = re.search(r"\{.*\}", raw, flags=re.DOTALL)
    if not match:
        return None
    snippet = match.group(0)
    try:
        obj = json.loads(snippet)
        if isinstance(obj, dict):
            return obj
    except Exception:
        return None
    return None


def call_llm_judge(target: Dict[str, str], summary: Dict[str, Any]) -> Tuple[bool, Dict[str, Any], str]:
    system_prompt = (
        "You are an internal quality judge for autonomous agents. "
        "Output JSON only with keys: quality_delta, kudos, coach, risk. "
        "quality_delta must be one of -1, 0, 1. "
        "kudos and coach must each be <= 140 chars. "
        "risk must be low, medium, or high. "
        "Do not suggest exposing internals/errors/tools to end users. "
        "Do not suggest asking blocking clarifying questions before searching."
    )
    user_prompt = (
        "Evaluate this completed run telemetry. "
        "Return compact JSON only.\n"
        + json.dumps(summary, separators=(",", ":"), ensure_ascii=True)
    )

    payload = {
        "model": target["model"],
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "temperature": 0,
        "max_tokens": 180,
    }
    body = json.dumps(payload).encode("utf-8")

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {target['api_key']}",
    }
    if target.get("agent_id"):
        headers["x-openclaw-agent-id"] = str(target["agent_id"])
    req = urlrequest.Request(
        target["endpoint"],
        data=body,
        headers=headers,
        method="POST",
    )

    try:
        with urlrequest.urlopen(req, timeout=20) as resp:
            raw = resp.read().decode("utf-8", errors="ignore")
    except urlerror.URLError as exc:
        return False, {}, f"judge_http_error:{exc}"
    except Exception as exc:  # pragma: no cover
        return False, {}, f"judge_error:{exc}"

    try:
        data = json.loads(raw)
    except Exception:
        return False, {}, "judge_non_json_response"
    content = (
        (data.get("choices", [{}])[0] or {})
        .get("message", {})
        .get("content", "")
    )
    obj = extract_json_object(str(content))
    if not obj:
        return False, {}, "judge_invalid_payload"

    delta = int(obj.get("quality_delta", 0))
    if delta > 1:
        delta = 1
    if delta < -1:
        delta = -1
    risk = str(obj.get("risk", "medium")).strip().lower()
    if risk not in {"low", "medium", "high"}:
        risk = "medium"

    judged = {
        "quality_delta": delta,
        "kudos": short_text(str(obj.get("kudos", "")), 140),
        "coach": short_text(str(obj.get("coach", "")), 140),
        "risk": risk,
    }
    return True, judged, "ok"


def merge_judge_feedback(
    positives: List[str],
    improvements: List[str],
    scores: Dict[str, Any],
    judged: Dict[str, Any],
) -> Dict[str, Any]:
    delta = int(judged.get("quality_delta", 0))
    scores["overall"] = round(clamp(float(scores["overall"]) + (0.3 * delta), 0.0, 5.0), 2)
    if scores["overall"] >= 4.5:
        scores["severity"] = "excellent"
    elif scores["overall"] >= 3.5:
        scores["severity"] = "healthy"
    elif scores["overall"] >= 2.5:
        scores["severity"] = "watch"
    else:
        scores["severity"] = "action"

    kudos = str(judged.get("kudos", "")).strip()
    coach = str(judged.get("coach", "")).strip()
    if kudos:
        positives.insert(0, kudos)
    if coach:
        improvements.insert(0, coach)
    return {
        "positives": positives[:3],
        "improvements": improvements[:3],
        "scores": scores,
    }


def compute_trend(prev_ewma: Optional[float], overall: float) -> Tuple[float, str]:
    if prev_ewma is None:
        return overall, "flat"
    alpha = 0.2
    new_ewma = round((alpha * overall) + ((1.0 - alpha) * prev_ewma), 3)
    drift = new_ewma - prev_ewma
    if drift > 0.08:
        return new_ewma, "up"
    if drift < -0.08:
        return new_ewma, "down"
    return new_ewma, "flat"


def append_history_point(state: Dict[str, Any], record: Dict[str, Any]) -> None:
    points = state.get("history_points", [])
    if not isinstance(points, list):
        points = []
    scores = record["scores"]
    points.append(
        {
            "epoch": parse_int(record.get("epoch", 0), 0),
            "event_key": str(record.get("event_key", "")),
            "overall": float(scores.get("overall", 0.0)),
            "reliability": float(scores.get("reliability", 0.0)),
            "efficiency": float(scores.get("efficiency", 0.0)),
            "hygiene": float(scores.get("hygiene", 0.0)),
            "severity": str(scores.get("severity", "watch")),
        }
    )
    state["history_points"] = points[-2000:]


def _window_direction(delta: float, threshold: float = 0.12) -> str:
    if delta > threshold:
        return "up"
    if delta < -threshold:
        return "down"
    return "flat"


def build_history_signal(history_points: List[Dict[str, Any]]) -> Dict[str, Any]:
    scores = [parse_float(x.get("overall", 0.0), 0.0) for x in history_points]
    reli = [parse_float(x.get("reliability", 0.0), 0.0) for x in history_points]
    eff = [parse_float(x.get("efficiency", 0.0), 0.0) for x in history_points]
    hyg = [parse_float(x.get("hygiene", 0.0), 0.0) for x in history_points]

    def compare(window: int) -> Dict[str, Any]:
        if len(scores) < window:
            avg_recent = average(scores)
            return {
                "window": window,
                "recent_avg": round(avg_recent, 3),
                "prior_avg": None,
                "delta": None,
                "direction": "flat",
            }
        recent = scores[-window:]
        prior = scores[-(window * 2) : -window] if len(scores) >= (window * 2) else scores[:-window]
        recent_avg = average(recent)
        prior_avg = average(prior) if prior else recent_avg
        delta = round(recent_avg - prior_avg, 3)
        return {
            "window": window,
            "recent_avg": round(recent_avg, 3),
            "prior_avg": round(prior_avg, 3),
            "delta": delta,
            "direction": _window_direction(delta),
        }

    short_cmp = compare(10)
    long_cmp = compare(30)
    return {
        "samples": len(scores),
        "best_overall": round(max(scores), 3) if scores else None,
        "worst_overall": round(min(scores), 3) if scores else None,
        "avg_overall": round(average(scores), 3) if scores else None,
        "avg_reliability": round(average(reli), 3) if reli else None,
        "avg_efficiency": round(average(eff), 3) if eff else None,
        "avg_hygiene": round(average(hyg), 3) if hyg else None,
        "short_term": short_cmp,
        "long_term": long_cmp,
    }


def update_feedback_uptake(
    state: Dict[str, Any],
    current_overall: float,
    current_severity: str,
    current_event_key: str,
    current_run_index: int,
) -> Dict[str, Any]:
    uptake = state.get("feedback_uptake", {})
    if not isinstance(uptake, dict):
        uptake = {}
    improved_count = parse_int(uptake.get("improved", 0), 0)
    not_improved_count = parse_int(uptake.get("not_improved", 0), 0)

    existing = state.get("feedback_followups", [])
    if not isinstance(existing, list):
        existing = []
    active: List[Dict[str, Any]] = []
    resolved_now = {"improved": 0, "not_improved": 0}
    for item in existing:
        if not isinstance(item, dict):
            continue
        baseline = parse_float(item.get("baseline_overall", 0.0), 0.0)
        created_run = parse_int(item.get("run_index", 0), 0)
        max_wait = parse_int(item.get("max_wait_runs", 5), 5)
        target_delta = parse_float(item.get("target_delta", 0.35), 0.35)

        if current_run_index <= created_run:
            active.append(item)
            continue

        if current_overall >= (baseline + target_delta):
            improved_count += 1
            resolved_now["improved"] += 1
            continue
        if (current_run_index - created_run) >= max_wait:
            not_improved_count += 1
            resolved_now["not_improved"] += 1
            continue
        active.append(item)

    if current_severity in {"watch", "action"}:
        active.append(
            {
                "event_key": current_event_key,
                "run_index": current_run_index,
                "baseline_overall": round(current_overall, 3),
                "target_delta": 0.35,
                "max_wait_runs": 5,
            }
        )

    active = active[-500:]
    state["feedback_followups"] = active
    state["feedback_uptake"] = {
        "improved": improved_count,
        "not_improved": not_improved_count,
    }

    denominator = improved_count + not_improved_count
    uptake_rate = round((improved_count / denominator), 3) if denominator > 0 else None
    return {
        "improved": improved_count,
        "not_improved": not_improved_count,
        "in_progress": len(active),
        "uptake_rate": uptake_rate,
        "resolved_this_run": resolved_now,
    }


def is_real_email(email: str) -> bool:
    if not email:
        return False
    email = email.strip().lower()
    if "{" in email or "}" in email:
        return False
    if "not set" in email:
        return False
    parts = email.split("@")
    if len(parts) != 2:
        return False
    if parts[1] in EXAMPLE_EMAIL_DOMAINS:
        return False
    return bool(EMAIL_RE.fullmatch(email))


def first_email(text: str) -> str:
    for hit in EMAIL_RE.findall(text or ""):
        if is_real_email(hit):
            return hit
    return ""


def resolve_owner_email(agent_paths: Dict[str, Path], env_map: Dict[str, str]) -> str:
    for key in ("LEARNING_FEEDBACK_EMAIL", "OWNER_EMAIL", "ADMIN_EMAIL"):
        candidate = env_map.get(key, "").strip()
        if is_real_email(candidate):
            return candidate

    todo_path = agent_paths["agent_workspace"] / "TODO.md"
    user_path = agent_paths["agent_workspace"] / "USER.md"
    for path in (todo_path, user_path):
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        candidate = first_email(text)
        if candidate:
            return candidate
    return ""


def format_owner_email_body(record: Dict[str, Any]) -> str:
    metrics = record["metrics"]
    scores = record["scores"]
    positives = record["positives"]
    improvements = record["improvements"]
    history_signal = record.get("history_signal", {})
    uptake = record.get("feedback_uptake", {})
    quality_signal = str(record.get("quality_signal", ""))
    lines = [
        "INTERNAL AGENT QUALITY FEEDBACK (never user-visible)",
        "",
        f"Agent: {record['agent']}",
        f"Timestamp: {record['timestamp']}",
        f"Run key: {record['event_key']}",
        f"Session: {record.get('session_id') or 'unknown'}",
        f"Channel: {metrics.get('channel', 'unknown')}",
        f"Model: {metrics.get('provider', '?')}/{metrics.get('model', '?')}",
        "",
        f"Overall score: {scores['overall']:.2f}/5 ({scores['severity']})",
        (
            f"Subscores: reliability={scores['reliability']:.2f}, "
            f"efficiency={scores['efficiency']:.2f}, hygiene={scores['hygiene']:.2f}"
        ),
        (
            "History delta (10-run): "
            f"{history_signal.get('short_term', {}).get('delta')} "
            f"({history_signal.get('short_term', {}).get('direction', 'flat')})"
        ),
        (
            "Feedback uptake: "
            f"improved={uptake.get('improved', 0)}, "
            f"not_improved={uptake.get('not_improved', 0)}, "
            f"in_progress={uptake.get('in_progress', 0)}"
        ),
        f"Quality signal: {quality_signal}",
        "",
        "Positives:",
    ]
    for item in positives:
        lines.append(f"- {item}")

    lines.extend(["", "Coaching priorities:"])
    for item in improvements:
        lines.append(f"- {item}")

    lines.extend(
        [
            "",
            "Telemetry:",
            f"- duration_ms={metrics.get('duration_ms', 0)}",
            f"- aborted={metrics.get('aborted', False)}",
            f"- prompt_rounds={metrics.get('prompt_rounds', 0)}",
            f"- tool_calls_total={metrics.get('tool_calls_total', 0)}",
            f"- tool_failures={metrics.get('tool_failures', 0)}",
            f"- errors={metrics.get('error_count', 0)} warnings={metrics.get('warn_count', 0)}",
            "",
            "This message is for owner/configurator only.",
        ]
    )
    return "\n".join(lines)


def send_email_message(
    agent_paths: Dict[str, Path],
    env_map: Dict[str, str],
    recipient: str,
    subject: str,
    body: str,
) -> Tuple[bool, str]:
    owner_email = resolve_owner_email(agent_paths, env_map)
    if not recipient and owner_email:
        recipient = owner_email
    if not recipient:
        return False, "owner_email_not_found"

    smtp_from = env_map.get("SMTP_FROM_EMAIL", "").strip()
    smtp_pass = env_map.get("GMAIL_APP_PASSWORD", "").strip()
    if not smtp_from or not smtp_pass:
        return False, "smtp_credentials_missing"

    send_script = agent_paths["agent_workspace"] / "scripts" / "send-email.sh"
    if not send_script.exists():
        return False, "send_email_script_missing"

    with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as tmp:
        tmp.write(body)
        tmp_path = tmp.name

    cmd = ["bash", str(send_script), recipient, subject, tmp_path]
    env = os.environ.copy()
    env["SMTP_FROM_EMAIL"] = smtp_from
    env["GMAIL_APP_PASSWORD"] = smtp_pass

    try:
        proc = subprocess.run(
            cmd,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except Exception as exc:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        return False, f"email_send_error:{exc}"

    try:
        os.unlink(tmp_path)
    except OSError:
        pass

    if proc.returncode == 0:
        return True, "email_sent"
    stderr = short_text(proc.stderr or proc.stdout or "", 160)
    return False, f"email_failed:{stderr}"


def build_digest_item(record: Dict[str, Any]) -> Dict[str, Any]:
    metrics = record["metrics"]
    scores = record["scores"]
    return {
        "timestamp": record["timestamp"],
        "epoch": parse_int(record["epoch"], 0),
        "event_key": record["event_key"],
        "overall": parse_float(scores["overall"], 0.0),
        "reliability": parse_float(scores["reliability"], 0.0),
        "efficiency": parse_float(scores["efficiency"], 0.0),
        "hygiene": parse_float(scores["hygiene"], 0.0),
        "severity": scores["severity"],
        "duration_ms": parse_int(metrics.get("duration_ms", 0), 0),
        "aborted": bool(metrics.get("aborted", False)),
        "tool_failures": parse_int(metrics.get("tool_failures", 0), 0),
        "errors": parse_int(metrics.get("error_count", 0), 0),
        "warnings": parse_int(metrics.get("warn_count", 0), 0),
        "coach": (record.get("improvements") or [""])[0],
        "kudos": (record.get("positives") or [""])[0],
    }


def summarize_history_quality(record: Dict[str, Any]) -> str:
    history_signal = record.get("history_signal", {}) or {}
    short_term = history_signal.get("short_term", {}) or {}
    long_term = history_signal.get("long_term", {}) or {}
    uptake = record.get("feedback_uptake", {}) or {}

    short_dir = short_term.get("direction", "flat")
    long_dir = long_term.get("direction", "flat")
    improved = parse_int(uptake.get("improved", 0), 0)
    not_improved = parse_int(uptake.get("not_improved", 0), 0)
    in_progress = parse_int(uptake.get("in_progress", 0), 0)

    if short_dir == "up" and improved >= not_improved:
        return "Signal: quality is trending up and feedback uptake appears positive."
    if short_dir == "down" and not_improved > improved:
        return "Signal: quality is trending down; corrective feedback is not sticking yet."
    if long_dir == "up":
        return "Signal: long-term quality direction is positive."
    if long_dir == "down":
        return "Signal: long-term quality direction is negative; intervention recommended."
    if in_progress > 0:
        return "Signal: feedback cycles are in progress; monitor next runs for resolution."
    return "Signal: quality is stable; no clear directional drift."


def format_digest_email_body(agent: str, pending: List[Dict[str, Any]], record: Dict[str, Any]) -> str:
    if not pending:
        return "No pending digest entries."

    scores = [parse_float(x.get("overall", 0.0), 0.0) for x in pending]
    reli = [parse_float(x.get("reliability", 0.0), 0.0) for x in pending]
    eff = [parse_float(x.get("efficiency", 0.0), 0.0) for x in pending]
    hyg = [parse_float(x.get("hygiene", 0.0), 0.0) for x in pending]
    severities = Counter(str(x.get("severity", "watch")) for x in pending)

    split = max(1, len(scores) // 2)
    first_half = scores[:split]
    second_half = scores[split:] if len(scores) > split else scores
    first_avg = average(first_half)
    second_avg = average(second_half)
    half_delta = round(second_avg - first_avg, 3)
    half_direction = _window_direction(half_delta, threshold=0.08)

    start_ts = pending[0].get("timestamp", "")
    end_ts = pending[-1].get("timestamp", "")
    history_signal = record.get("history_signal", {}) or {}
    short_term = history_signal.get("short_term", {}) or {}
    long_term = history_signal.get("long_term", {}) or {}
    uptake = record.get("feedback_uptake", {}) or {}

    lines = [
        "INTERNAL AGENT QUALITY DIGEST (never user-visible)",
        "",
        f"Agent: {agent}",
        f"Period: {start_ts}  →  {end_ts}",
        f"Runs in digest: {len(pending)}",
        "",
        "Quality summary:",
        f"- Avg overall: {average(scores):.3f}/5",
        f"- Avg reliability: {average(reli):.3f}",
        f"- Avg efficiency: {average(eff):.3f}",
        f"- Avg hygiene: {average(hyg):.3f}",
        f"- Best/Worst overall: {max(scores):.3f} / {min(scores):.3f}",
        (
            f"- In-digest drift: {half_delta:+.3f} ({half_direction}) "
            "[second half vs first half]"
        ),
        (
            "- 10-run delta: "
            f"{short_term.get('delta')} ({short_term.get('direction', 'flat')})"
        ),
        (
            "- 30-run delta: "
            f"{long_term.get('delta')} ({long_term.get('direction', 'flat')})"
        ),
        "",
        "Severity counts:",
        f"- excellent={severities.get('excellent', 0)}",
        f"- healthy={severities.get('healthy', 0)}",
        f"- watch={severities.get('watch', 0)}",
        f"- action={severities.get('action', 0)}",
        "",
        "Feedback uptake:",
        f"- improved={parse_int(uptake.get('improved', 0), 0)}",
        f"- not_improved={parse_int(uptake.get('not_improved', 0), 0)}",
        f"- in_progress={parse_int(uptake.get('in_progress', 0), 0)}",
        f"- uptake_rate={uptake.get('uptake_rate')}",
        "",
        summarize_history_quality(record),
        "",
        "Recent run samples:",
    ]
    for item in pending[-15:]:
        lines.append(
            (
                f"- {item.get('timestamp')} "
                f"overall={parse_float(item.get('overall', 0.0), 0.0):.2f} "
                f"sev={item.get('severity')} "
                f"dur={parse_int(item.get('duration_ms', 0), 0)}ms "
                f"fails={parse_int(item.get('tool_failures', 0), 0)} "
                f"errs={parse_int(item.get('errors', 0), 0)} "
                f"aborted={bool(item.get('aborted', False))}"
            )
        )

    lines.extend(["", "Top coaching cues in this digest:"])
    coaching_counts = Counter(short_text(str(x.get("coach", "")), 90) for x in pending if x.get("coach"))
    if coaching_counts:
        for cue, count in coaching_counts.most_common(5):
            lines.append(f"- ({count}x) {cue}")
    else:
        lines.append("- No recurring coaching cues.")

    lines.extend(["", "This digest is for owner/configurator only."])
    return "\n".join(lines)


def maybe_dispatch_owner_notification(
    agent_paths: Dict[str, Path],
    env_map: Dict[str, str],
    state: Dict[str, Any],
    record: Dict[str, Any],
) -> Tuple[bool, str]:
    mode = env_map.get("LEARNING_FEEDBACK_EMAIL_MODE", "immediate").strip().lower()
    if mode in {"off", "disabled", "0", "false"}:
        return False, "email_disabled"

    recipient = resolve_owner_email(agent_paths, env_map)
    if not recipient:
        return False, "owner_email_not_found"

    if mode == "immediate":
        subject = (
            f"[ironclaw] quality {record['agent']} "
            f"{record['scores']['severity']} {record['scores']['overall']:.2f}/5"
        )
        body = format_owner_email_body(record)
        return send_email_message(agent_paths, env_map, recipient, subject, body)

    if mode != "digest":
        return False, f"unknown_email_mode:{mode}"

    digest_state = state.get("digest", {})
    if not isinstance(digest_state, dict):
        digest_state = {"pending": [], "last_sent_epoch": None}
    pending = digest_state.get("pending", [])
    if not isinstance(pending, list):
        pending = []
    pending.append(build_digest_item(record))
    pending = pending[-500:]
    digest_state["pending"] = pending
    state["digest"] = digest_state

    min_runs = parse_int_env(env_map, "LEARNING_FEEDBACK_DIGEST_MIN_RUNS", 10, 1, 1000)
    min_minutes = parse_int_env(env_map, "LEARNING_FEEDBACK_DIGEST_MINUTES", 120, 5, 7 * 24 * 60)

    now_ts = parse_int(record.get("epoch", now_epoch()), now_epoch())
    last_sent = digest_state.get("last_sent_epoch")
    last_sent = parse_int(last_sent, 0) if last_sent is not None else None
    due_runs = len(pending) >= min_runs
    due_time = (last_sent is not None) and ((now_ts - last_sent) >= (min_minutes * 60)) and len(pending) > 0
    force_send = parse_bool(env_map.get("LEARNING_FEEDBACK_DIGEST_FORCE", "false"))

    if not (due_runs or due_time or force_send):
        return False, f"digest_queued:{len(pending)}"

    subject = (
        f"[ironclaw] quality digest {record['agent']} "
        f"{record.get('history_signal', {}).get('short_term', {}).get('direction', 'flat')}"
    )
    body = format_digest_email_body(record["agent"], pending, record)
    ok, status = send_email_message(agent_paths, env_map, recipient, subject, body)
    if ok:
        digest_state["pending"] = []
        digest_state["last_sent_epoch"] = now_ts
        state["digest"] = digest_state
        if force_send:
            env_map["LEARNING_FEEDBACK_DIGEST_FORCE"] = "false"
        return True, f"digest_sent:{len(pending)}"
    return False, status


def write_latest_text(path: Path, record: Dict[str, Any]) -> None:
    metrics = record["metrics"]
    scores = record["scores"]
    history_signal = record.get("history_signal", {})
    short_term = history_signal.get("short_term", {})
    long_term = history_signal.get("long_term", {})
    uptake = record.get("feedback_uptake", {})
    quality_signal = str(record.get("quality_signal", ""))
    lines = [
        f"agent={record['agent']}",
        f"timestamp={record['timestamp']}",
        f"event_key={record['event_key']}",
        f"session_id={record.get('session_id') or 'unknown'}",
        f"channel={metrics.get('channel', 'unknown')}",
        f"model={metrics.get('provider', '?')}/{metrics.get('model', '?')}",
        f"overall={scores['overall']}",
        f"severity={scores['severity']}",
        f"duration_ms={metrics.get('duration_ms', 0)}",
        f"aborted={metrics.get('aborted', False)}",
        f"tool_calls={metrics.get('tool_calls_total', 0)}",
        f"errors={metrics.get('error_count', 0)}",
        f"warnings={metrics.get('warn_count', 0)}",
        (
            f"history_short_delta={short_term.get('delta')} "
            f"({short_term.get('direction', 'flat')})"
        ),
        (
            f"history_long_delta={long_term.get('delta')} "
            f"({long_term.get('direction', 'flat')})"
        ),
        (
            f"feedback_uptake improved={uptake.get('improved', 0)} "
            f"not_improved={uptake.get('not_improved', 0)} "
            f"in_progress={uptake.get('in_progress', 0)} "
            f"rate={uptake.get('uptake_rate')}"
        ),
        f"quality_signal={quality_signal}",
        "",
        "positives:",
    ]
    for item in record["positives"]:
        lines.append(f"- {item}")
    lines.append("")
    lines.append("improvements:")
    for item in record["improvements"]:
        lines.append(f"- {item}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _normalize_cue(text: str) -> str:
    """Normalize for deduplication: lowercase, collapse whitespace."""
    return " ".join((text or "").lower().split())


def _should_skip_cue(cue: str) -> bool:
    """Skip generic/no-op coaching that adds no value."""
    norm = _normalize_cue(cue)
    if len(norm) < 15:
        return True
    for pat in COACHING_SKIP_PATTERNS:
        if pat in norm:
            return True
    return False


def _deterministic_merge_cues(new_cues: List[str], existing_cues: List[str]) -> List[str]:
    """Fallback: merge new + existing, dedupe by normalized text, cap at COACHING_MAX_ITEMS."""
    seen: set[str] = set()
    merged: List[str] = []
    for cue in new_cues + existing_cues:
        norm = _normalize_cue(cue)
        if norm in seen:
            continue
        seen.add(norm)
        merged.append(cue)
        if len(merged) >= COACHING_MAX_ITEMS:
            break
    return merged


def upsert_coaching_section(
    agent_paths: Dict[str, Path],
    record: Dict[str, Any],
    env_map: Dict[str, str],
) -> Tuple[bool, float]:
    """
    Upsert quality coaching into workspace/AGENTS.md so OpenClaw injects it every turn.

    - Reads existing AGENTS.md and parses the coaching section (if present).
    - Merges new cues from this run's improvements (LLM judge + deterministic).
    - Deduplicates by normalized text, keeps most recent/relevant cues.
    - Writes atomically. Runs on every feedback pass when improvements exist.
    """
    if parse_bool(env_map.get("LEARNING_FEEDBACK_INJECT_COACHING", "true")) is False:
        return False, 0.0

    improvements = record.get("improvements") or []
    new_cues = [
        short_text(str(x).strip(), 200)
        for x in improvements
        if x and not _should_skip_cue(str(x))
    ]
    if not new_cues:
        return False, 0.0

    agents_md = agent_paths["agent_workspace"] / "AGENTS.md"
    if not agents_md.exists():
        return False, 0.0

    try:
        content = agents_md.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return False, 0.0

    # Parse existing coaching section: between header and next ## or EOF.
    header_pos = content.find(COACHING_SECTION_HEADER)
    if header_pos >= 0:
        rest = content[header_pos + len(COACHING_SECTION_HEADER) :]
        next_h2 = rest.find("\n## ")
        section_end = len(content) if next_h2 < 0 else header_pos + len(COACHING_SECTION_HEADER) + next_h2
        before = content[:header_pos]
        after = content[section_end:]
        existing_block = content[header_pos:section_end]
        # Extract bullet lines (e.g. "- something")
        existing_cues = [
            m.group(1).strip()
            for m in re.finditer(r"^\s*-\s+(.+)$", existing_block, re.MULTILINE)
        ]
    else:
        before = content.rstrip()
        if before and not before.endswith("\n"):
            before += "\n"
        after = ""
        existing_cues = []

    # Merge via LLM (semantic dedup) when target available; fallback to deterministic.
    config = parse_json_file(agent_paths["agent_config"]) or {}
    conf = parse_agent_conf(agent_paths["agent_conf"])
    coaching_target = resolve_coaching_target(config, env_map, conf)
    merged: List[str] = []
    coaching_cost_usd = 0.0
    coaching_llm_used = False

    if coaching_target:
        ok, merged, usage_info = call_coaching_merge_llm(coaching_target, existing_cues, new_cues)
        if ok and merged:
            coaching_llm_used = True
            coaching_cost_usd = compute_coaching_cost(
                coaching_target.get("provider", ""),
                coaching_target.get("model", ""),
                usage_info,
            )
            learning_dir = agent_paths["agent_logs"] / "learning"
            costs_file = learning_dir / "coaching-costs.jsonl"
            if coaching_cost_usd > 0:
                cost_record = {
                    "timestamp": now_iso(),
                    "agent": record.get("agent", ""),
                    "event_key": record.get("event_key", ""),
                    "model": coaching_target.get("model", ""),
                    "prompt_tokens": usage_info.get("prompt_tokens", 0),
                    "completion_tokens": usage_info.get("completion_tokens", 0),
                    "cost_usd": coaching_cost_usd,
                }
                try:
                    with costs_file.open("a", encoding="utf-8") as f:
                        f.write(json.dumps(cost_record, ensure_ascii=True) + "\n")
                except OSError:
                    pass

    if not merged:
        merged = _deterministic_merge_cues(new_cues, existing_cues)

    if not merged:
        return False, 0.0

    section_lines = [
        "",
        COACHING_SECTION_HEADER,
        "",
        COACHING_SECTION_INTRO,
        "",
    ]
    for cue in merged:
        section_lines.append(f"- {cue}")
    section_lines.append("")

    new_content = before + "\n".join(section_lines) + after
    if new_content == content:
        return False, coaching_cost_usd

    tmp = agents_md.with_suffix(".md.tmp")
    try:
        tmp.write_text(new_content, encoding="utf-8")
        tmp.replace(agents_md)
        return True, coaching_cost_usd
    except OSError:
        return False, coaching_cost_usd
    finally:
        tmp.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate one completed run for internal learning feedback.")
    parser.add_argument("agent", help="agent directory name under agents/")
    parser.add_argument("--log-file", required=True, help="path to current openclaw log file")
    parser.add_argument("--run-id", default="", help="runId from embedded run done")
    parser.add_argument("--session-id", default="", help="sessionId from embedded run done")
    parser.add_argument("--duration-ms", type=int, default=0, help="durationMs from embedded run done")
    parser.add_argument("--aborted", default="false", help="aborted flag from embedded run done")
    parser.add_argument("--done-msg", default="", help="raw done message (for fallback dedupe)")
    parser.add_argument("--max-log-lines", type=int, default=6000, help="recent lines to inspect")
    parser.add_argument("--dry-run", action="store_true", help="do not write files or send email")
    args = parser.parse_args()

    agent_paths = resolve_agent(args.agent)
    conf = parse_agent_conf(agent_paths["agent_conf"])
    env_map = parse_key_value_file(agent_paths["agent_env"])

    aborted = parse_bool(args.aborted)
    event_key = build_event_key(args.run_id.strip(), args.done_msg.strip(), args.session_id.strip(), args.duration_ms, aborted)

    learning_dir = agent_paths["agent_logs"] / "learning"
    learning_dir.mkdir(parents=True, exist_ok=True)
    state_path = learning_dir / "state.json"
    latest_txt = learning_dir / "latest-feedback.txt"
    feedback_file = learning_dir / f"feedback-{time.strftime('%Y-%m-%d')}.jsonl"
    timeseries_file = learning_dir / "quality-timeseries.jsonl"

    state = load_state(state_path)
    processed_list = [str(x) for x in state.get("processed_keys", [])]
    processed_set = set(processed_list)
    if event_key in processed_set:
        print(f"LEARN_SKIP duplicate event_key={event_key}")
        return

    log_file = Path(args.log_file)
    entries = read_recent_log_entries(log_file, max(200, args.max_log_lines))
    metrics = collect_run_context(
        entries=entries,
        run_id=args.run_id.strip(),
        session_id=args.session_id.strip(),
        done_msg=args.done_msg.strip(),
        duration_ms_arg=args.duration_ms,
        aborted_arg=aborted,
    )
    scores = score_run(metrics)
    positives, improvements = build_feedback_lines(metrics, scores)

    llm_used = False
    llm_status = "skipped"
    llm_judge: Dict[str, Any] = {}

    disable_llm = parse_bool(env_map.get("LEARNING_FEEDBACK_DISABLE_LLM_JUDGE", "false"))
    eval_count = int(state.get("total_evaluated", 0) or 0)
    should_call_llm = (
        not disable_llm
        and (
            scores["overall"] <= 3.6
            or int(metrics.get("error_count", 0)) > 0
            or int(metrics.get("tool_failures", 0)) > 0
            or (eval_count % 5 == 0)
        )
    )

    if should_call_llm:
        config = parse_json_file(agent_paths["agent_config"]) or {}
        judge_target = resolve_judge_target(config, env_map, conf)
        if judge_target:
            summary = {
                "agent": args.agent,
                "event_key": event_key,
                "metrics": metrics,
                "scores": scores,
                "notes": metrics.get("notes", []),
            }
            llm_used, llm_judge, llm_status = call_llm_judge(judge_target, summary)
            if llm_used:
                merged = merge_judge_feedback(positives, improvements, scores, llm_judge)
                positives = merged["positives"]
                improvements = merged["improvements"]
                scores = merged["scores"]
                llm_judge["provider"] = judge_target["provider"]
                llm_judge["model"] = judge_target["model"]
        else:
            llm_status = "judge_target_unavailable"

    run_index = parse_int(state.get("total_evaluated", 0), 0) + 1
    ewma, trend = compute_trend(state.get("ewma_overall"), parse_float(scores["overall"], 0.0))
    record = {
        "timestamp": now_iso(),
        "epoch": now_epoch(),
        "agent": args.agent,
        "agent_port": conf.get("AGENT_PORT", ""),
        "event_key": event_key,
        "run_id": args.run_id.strip(),
        "session_id": args.session_id.strip(),
        "run_index": run_index,
        "metrics": metrics,
        "scores": scores,
        "positives": positives,
        "improvements": improvements,
        "llm_judge": {
            "used": llm_used,
            "status": llm_status,
            **llm_judge,
        },
        "trend": {
            "ewma_overall": ewma,
            "direction": trend,
        },
    }

    append_history_point(state, record)
    history_signal = build_history_signal(state.get("history_points", []))
    feedback_uptake = update_feedback_uptake(
        state=state,
        current_overall=parse_float(scores["overall"], 0.0),
        current_severity=str(scores["severity"]),
        current_event_key=event_key,
        current_run_index=run_index,
    )
    record["history_signal"] = history_signal
    record["feedback_uptake"] = feedback_uptake
    record["quality_signal"] = summarize_history_quality(record)

    email_sent = False
    email_status = "skipped"
    coaching_injected = False
    coaching_cost_usd = 0.0
    if not args.dry_run:
        with feedback_file.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=True) + "\n")

        timeseries_point = {
            "timestamp": record["timestamp"],
            "epoch": record["epoch"],
            "event_key": record["event_key"],
            "run_index": run_index,
            "overall": scores["overall"],
            "reliability": scores["reliability"],
            "efficiency": scores["efficiency"],
            "hygiene": scores["hygiene"],
            "severity": scores["severity"],
            "short_delta": history_signal.get("short_term", {}).get("delta"),
            "short_direction": history_signal.get("short_term", {}).get("direction"),
            "long_delta": history_signal.get("long_term", {}).get("delta"),
            "long_direction": history_signal.get("long_term", {}).get("direction"),
            "feedback_uptake_rate": feedback_uptake.get("uptake_rate"),
        }
        with timeseries_file.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(timeseries_point, ensure_ascii=True) + "\n")

        write_latest_text(latest_txt, record)
        coaching_injected, coaching_cost_usd = upsert_coaching_section(agent_paths, record, env_map)
        email_sent, email_status = maybe_dispatch_owner_notification(agent_paths, env_map, state, record)

        processed_list.append(event_key)
        # Keep bounded dedupe window.
        processed_list = processed_list[-5000:]
        state["processed_keys"] = processed_list
        state["total_evaluated"] = run_index
        state["ewma_overall"] = ewma
        state["last_updated"] = now_iso()
        save_state(state_path, state)

    coaching_str = " coaching=injected" if coaching_injected else (" coaching=skipped" if record.get("improvements") else "")
    cost_str = f" coaching_cost=${coaching_cost_usd:.6f}" if coaching_cost_usd > 0 else ""
    print(
        "LEARN_OK "
        f"agent={args.agent} "
        f"score={scores['overall']:.2f} "
        f"severity={scores['severity']} "
        f"event={event_key} "
        f"hist={history_signal.get('short_term', {}).get('direction', 'flat')} "
        f"llm={llm_status} "
        f"email={email_status if (email_sent and str(email_status).startswith('digest_sent:')) else ('sent' if email_sent else email_status)}"
        f"{coaching_str}"
        f"{cost_str}"
    )


if __name__ == "__main__":
    main()
