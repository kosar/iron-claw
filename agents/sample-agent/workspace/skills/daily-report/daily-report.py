#!/usr/bin/env python3
"""
daily-report.py — Daily operational report for an IronClaw agent.
Usage: python3 daily-report.py <agent-name> [--date YYYY-MM-DD] [--save]

Generates a comprehensive report from OpenClaw logs and session files.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta
from collections import Counter, defaultdict
from pathlib import Path

IRONCLAW_ROOT = os.environ.get('IRONCLAW_ROOT', '/home/ai_sandbox/.openclaw')

def list_agents():
    """List all agent directories."""
    agents_dir = Path(IRONCLAW_ROOT) / 'agents'
    if not agents_dir.exists():
        return []
    return [d.name for d in agents_dir.iterdir() if d.is_dir()]

def resolve_agent(name=None):
    """Resolve agent paths and configuration."""
    if not name:
        agents = list_agents()
        if not agents:
            print("Error: No agent specified and no agents found", file=sys.stderr)
            sys.exit(1)
        name = agents[0]
    
    agent_dir = Path(IRONCLAW_ROOT) / 'agents' / name
    paths = {
        'name': name,
        'dir': agent_dir,
        'log_dir': agent_dir / 'logs',
        'sessions': agent_dir / 'sessions',
        'config': agent_dir / 'config',
        'workspace': agent_dir / 'workspace',
        'env_file': agent_dir / '.env',
    }
    
    # Create directories if needed
    for key in ['log_dir', 'sessions', 'config', 'workspace']:
        paths[key].mkdir(parents=True, exist_ok=True)
    
    return paths

def parse_log_file(log_path):
    """Parse OpenClaw log file for events."""
    events = []
    if not log_path.exists():
        return events
    
    with open(log_path, 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
                events.append(entry)
            except json.JSONDecodeError:
                continue
    return events

def parse_session_files(sessions_dir, date_str):
    """Parse session JSONL files for usage, tool calls, and channels."""
    costs = []
    tools = []
    channel_counts = {'bluebubbles': 0, 'telegram': 0, 'whatsapp': 0, 'webchat': 0, 'unknown': 0}
    session_channels = {}  # Track channel per session to avoid double counting
    
    if not sessions_dir.exists():
        return costs, tools, channel_counts
    
    for sess_file in sessions_dir.glob('*.jsonl'):
        session_id = sess_file.stem
        session_has_data = False
        
        with open(sess_file, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                
                # Check if this line is from target date
                if date_str not in line:
                    continue
                
                session_has_data = True
                
                try:
                    entry = json.loads(line)
                    msg = entry.get('message', {})
                    
                    # Detect channel from message content/metadata
                    if session_id not in session_channels:
                        line_lower = line.lower()
                        if 'bluebubbles' in line_lower or 'chat_guid' in line_lower:
                            session_channels[session_id] = 'bluebubbles'
                        elif 'telegram' in line_lower:
                            session_channels[session_id] = 'telegram'
                        elif 'whatsapp' in line_lower:
                            session_channels[session_id] = 'whatsapp'
                        elif 'webchat' in line_lower:
                            session_channels[session_id] = 'webchat'
                    
                    if msg.get('role') == 'assistant':
                        # Extract cost info
                        usage = msg.get('usage')
                        if usage:
                            costs.append({
                                'input': usage.get('input', 0),
                                'output': usage.get('output', 0),
                                'cache_read': usage.get('cacheRead', 0),
                                'cache_write': usage.get('cacheWrite', 0),
                                'cost': usage.get('cost', {}).get('total', 0),
                                'provider': msg.get('provider', 'unknown'),
                                'model': msg.get('model', 'unknown'),
                            })
                        
                        # Extract tool calls
                        content = msg.get('content', [])
                        for item in content if isinstance(content, list) else []:
                            if item.get('type') == 'toolCall':
                                tools.append({
                                    'name': item.get('name', 'unknown'),
                                    'args': item.get('arguments', {}),
                                })
                except (json.JSONDecodeError, KeyError):
                    continue
        
        # Count this session's channel
        if session_has_data:
            ch = session_channels.get(session_id, 'unknown')
            channel_counts[ch] = channel_counts.get(ch, 0) + 1
    
    return costs, tools, channel_counts

def get_ai_summary(agent_paths, report_text):
    """Get a smart summary of the report using the configured report_model."""
    # Config lives at the OpenClaw root (container: /home/ai_sandbox/.openclaw/openclaw.json)
    # Try agent-specific config first, fall back to root config
    config_file = agent_paths['config'] / 'openclaw.json'
    if not config_file.exists():
        config_file = Path(IRONCLAW_ROOT) / 'openclaw.json'

    if not config_file.exists():
        return ""

    try:
        with open(config_file, 'r') as f:
            config = json.load(f)

        # Use heartbeat model for summarization (no custom 'report' key needed in config)
        report_model = (config.get('agents', {}).get('defaults', {}).get('heartbeat', {}).get('model')
                        or 'openai/gpt-5-nano')

        # Get gateway port and token — token is an env var inside the container,
        # with .env file as fallback for host-side invocations
        port = config.get('gateway', {}).get('port', 18789)
        token = os.environ.get('OPENCLAW_GATEWAY_TOKEN', '')
        if not token:
            env_file = agent_paths['env_file']
            if env_file.exists():
                with open(env_file, 'r') as f:
                    for line in f:
                        if 'OPENCLAW_GATEWAY_TOKEN=' in line:
                            token = line.split('=', 1)[1].strip()

        if not token:
            return ""
            
        # Call the gateway
        payload = {
            "model": report_model,
            "messages": [
                {"role": "system", "content": "You are an operations analyst. Briefly summarize the following activity report for an autonomous agent. Focus on efficiency, anomalies, and cost. Keep it under 5 sentences. Use a professional tone."},
                {"role": "user", "content": report_text}
            ],
            "max_tokens": 500
        }
        
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}"
        }
        
        import urllib.request
        req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", 
                                   data=json.dumps(payload).encode('utf-8'),
                                   headers=headers)
        
        with urllib.request.urlopen(req, timeout=30) as response:
            res = json.loads(response.read().decode('utf-8'))
            return res['choices'][0]['message']['content'].strip()
            
    except Exception as e:
        return f"Could not generate AI summary: {str(e)}"

def parse_tool_calls_from_log(events):
    """Extract tool call counts directly from app log 'tool start' events.

    Sessions are stored in SQLite (not JSONL), so the session-file parser
    returns no tool data. This function reads tool names from the structured
    log entries, which reliably record every tool invocation.
    """
    counts = Counter()
    for e in events:
        msg = e.get('1', '')
        if isinstance(msg, str) and 'tool start:' in msg:
            m = re.search(r' tool=(\S+)', msg)
            if m:
                counts[m.group(1)] += 1
    return counts


def parse_scout_log(log_dir, date_str):
    """Parse restaurant-scout log for daily activity stats."""
    scout_log = Path(log_dir) / 'scout.log'
    if not scout_log.exists():
        scout_log = Path('/tmp/openclaw') / 'scout.log'

    stats = {'searches': 0, 'deeplinks': 0, 'restaurants': [], 'platforms': Counter()}
    if not scout_log.exists():
        return stats

    seen = set()
    with open(scout_log, 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            if date_str not in line:
                continue
            try:
                e = json.loads(line.strip())
                ev = e.get('event', '')
                if ev == 'scout_start':
                    stats['searches'] += 1
                    r = e.get('restaurant', '')
                    if r and r not in seen:
                        stats['restaurants'].append(r)
                        seen.add(r)
                elif ev == 'deeplink_built':
                    stats['deeplinks'] += 1
                    p = e.get('platform', '')
                    if p:
                        stats['platforms'][p] += 1
            except Exception:
                continue
    return stats


def generate_report(agent_paths, report_date, save=False):
    """Generate the daily report."""

    date_str = report_date.strftime('%Y-%m-%d')
    log_file = agent_paths['log_dir'] / f'openclaw-{date_str}.log'
    # Fallback to /tmp/openclaw/ which is the container log directory
    if not log_file.exists():
        log_file = Path('/tmp/openclaw') / f'openclaw-{date_str}.log'

    # Parse logs
    events = parse_log_file(log_file)

    # Parse sessions (costs only — sessions are SQLite so tool data comes from log)
    costs, _tools_unused, channel_counts = parse_session_files(agent_paths['sessions'], date_str)

    # Tool counts from app log (reliable source; replaces broken JSONL path)
    tool_counts = parse_tool_calls_from_log(events)

    # Skill-specific logs
    scout_stats = parse_scout_log(agent_paths['log_dir'], date_str)

    # Calculate metrics from logs (if available)
    run_events = [e for e in events if isinstance(e.get('1'), str) and 'embedded run' in e.get('1', '')]
    run_starts = [e for e in run_events if 'start' in e.get('1', '')]
    run_dones = [e for e in run_events if 'done' in e.get('1', '')]

    heartbeat_runs = [e for e in run_starts if 'heartbeat' in e.get('1', '')]
    user_runs = len(run_starts) - len(heartbeat_runs)

    errors = [e for e in events if e.get('_meta', {}).get('logLevelName') == 'ERROR']
    warnings = [e for e in events if e.get('_meta', {}).get('logLevelName') == 'WARN']
    
    # Cost aggregation
    total_cost = sum(c['cost'] for c in costs)
    total_input = sum(c['input'] for c in costs)
    total_output = sum(c['output'] for c in costs)
    model_counts = Counter(f"{c['provider']}/{c['model']}" for c in costs)
    
    # Hourly distribution
    hourly = [0] * 24
    for e in run_dones:
        ts = e.get('time', '')
        if 'T' in ts:
            hour = int(ts.split('T')[1][:2])
            hourly[hour] += 1
    
    # Parse model switches — switch-tier.sh writes to /tmp/openclaw/ inside the container
    switches = []
    switch_log = agent_paths['log_dir'] / 'model_switches.log'
    if not switch_log.exists():
        switch_log = Path('/tmp/openclaw') / 'model_switches.log'
    if switch_log.exists():
        with open(switch_log, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                if date_str in line:
                    try:
                        entry = json.loads(line)
                        switches.append(entry)
                    except json.JSONDecodeError:
                        continue

    # Generate report text
    lines = []
    def add(s): lines.append(s)
    def divider(): lines.append('─' * 52)
    def section(title): 
        lines.append('')
        lines.append(title)
        divider()
    
    # Header
    lines.append('═' * 52)
    add(f"  IRONCLAW DAILY REPORT  •  {agent_paths['name']}  •  {date_str}")
    lines.append('═' * 52)
    add(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}  |  Period: {date_str}")
    
    if not events and not costs and not tools and not switches:
        add("")
        add(f"No activity recorded for {date_str}")
    else:
        # Activity Overview
        section("ACTIVITY OVERVIEW")
        total_runs = len(run_starts)
        add(f"Total runs:           {total_runs}")
        add(f"  User-initiated:     {user_runs}")
        add(f"  Heartbeat runs:     {len(heartbeat_runs)}")
        add(f"Errors:               {len(errors)}")
        add(f"Warnings:             {len(warnings)}")
        
        # Model Switches
        if switches:
            section("MODEL SWITCHES")
            for sw in switches:
                t = sw.get('time', '').split('T')[1][:5]
                task = sw.get('task', 'primary')
                tier = sw.get('tier', 'unknown')
                reason = sw.get('reason', '')
                add(f"  [{t}] {task:9} → {tier:10} | {reason}")
        
        # Hourly sparkline
        max_h = max(hourly) if max(hourly) > 0 else 1
        blocks = "▁▂▃▄▅▆▇█"
        spark = ''
        for h in hourly:
            if h == 0:
                spark += ' '
            else:
                idx = min(7, int(h * 7 / max_h))
                spark += blocks[idx]
        add(f"Hourly activity:      |{spark}| (00-23h)")
        
        # Channel Activity
        section("CHANNEL ACTIVITY")
        for ch in ['telegram', 'bluebubbles', 'whatsapp', 'webchat', 'unknown']:
            if channel_counts[ch] > 0 or ch != 'unknown':
                add(f"{ch.capitalize():20} {channel_counts[ch]} conversations")
        
        # Cost & Tokens
        section("COST & TOKENS")
        if costs:
            add(f"Total cost:           ${total_cost:.4f}")
            add(f"  Input tokens:       {total_input:,}")
            add(f"  Output tokens:      {total_output:,}")
            add(f"  Turns counted:      {len(costs)}")
            add("")
            add("Model breakdown:")
            for model, cnt in model_counts.most_common():
                add(f"  {model:30} {cnt} turns")
        else:
            add("No cost data available")
        
        # Tool Usage
        section("TOOL USAGE")
        if tool_counts:
            for name, cnt in tool_counts.most_common(12):
                add(f"  {name:22} {cnt} calls")
        else:
            add("No tool calls recorded")

        # Web & Search Activity
        web_search_count = tool_counts.get('web_search', 0)
        web_fetch_count  = tool_counts.get('web_fetch', 0)
        browser_count    = tool_counts.get('browser', 0)
        if web_search_count or web_fetch_count or browser_count:
            section("WEB & SEARCH ACTIVITY")
            if web_search_count:
                add(f"  Web searches (Brave):  {web_search_count} queries")
            if web_fetch_count:
                add(f"  Page fetches:          {web_fetch_count} requests")
            if browser_count:
                add(f"  Browser sessions:      {browser_count} calls")

        # Skill Activity
        if scout_stats['searches'] > 0:
            section("SKILL ACTIVITY — RESTAURANT SCOUT 🍽️")
            add(f"  Lookups:               {scout_stats['searches']}")
            add(f"  Deep links built:      {scout_stats['deeplinks']}")
            if scout_stats['restaurants']:
                add(f"  Restaurants scouted:   {', '.join(scout_stats['restaurants'][:6])}")
            if scout_stats['platforms']:
                plat_str = '  '.join(f"{p}:{n}" for p, n in scout_stats['platforms'].most_common())
                add(f"  Platforms:             {plat_str}")

        # Errors
        if errors:
            section("ERRORS")
            error_msgs = [str(e.get('0', e.get('1', 'Unknown error')))[:80] for e in errors[:5]]
            for msg in error_msgs:
                add(f"  • {msg}")

    # AI Summary
    summary = get_ai_summary(agent_paths, '\n'.join(lines))
    if summary:
        section("AI SUMMARY")
        add(summary)
    
    lines.append('')
    lines.append('═' * 52)
    
    report_text = '\n'.join(lines)
    
    # Save if requested
    if save:
        reports_dir = agent_paths['log_dir'] / 'reports'
        reports_dir.mkdir(exist_ok=True)
        report_file = reports_dir / f'{date_str}.txt'
        with open(report_file, 'w') as f:
            f.write(report_text)
        print(f"Report saved: {report_file}", file=sys.stderr)
        
        # Save metrics JSONL
        metrics_file = reports_dir / 'metrics.jsonl'
        metrics = {
            'date': date_str,
            'runs_total': len(run_starts),
            'runs_user': user_runs,
            'runs_heartbeat': len(heartbeat_runs),
            'cost_total': total_cost,
            'input_tokens': total_input,
            'output_tokens': total_output,
            'errors': len(errors),
            'warnings': len(warnings),
            'channels': dict(channel_counts),
            'tool_calls': dict(tool_counts.most_common()),
            'web_searches': tool_counts.get('web_search', 0),
            'web_fetches': tool_counts.get('web_fetch', 0),
            'scout_lookups': scout_stats['searches'],
            'scout_deeplinks': scout_stats['deeplinks'],
        }
        with open(metrics_file, 'a') as f:
            f.write(json.dumps(metrics) + '\n')
    
    return report_text

def main():
    parser = argparse.ArgumentParser(description='Generate daily activity report')
    parser.add_argument('agent', nargs='?', help='Agent name')
    parser.add_argument('--date', help='Report date (YYYY-MM-DD)', default=None)
    parser.add_argument('--save', action='store_true', help='Save to file')
    parser.add_argument('--all', action='store_true', help='Generate for all agents')
    
    args = parser.parse_args()
    
    # Parse date
    if args.date:
        report_date = datetime.strptime(args.date, '%Y-%m-%d')
    else:
        report_date = datetime.now() - timedelta(days=1)
    
    if args.all:
        agents = list_agents()
        for agent_name in agents:
            paths = resolve_agent(agent_name)
            report = generate_report(paths, report_date, args.save)
            print(report)
            print('\n' + '='*52 + '\n')
    else:
        paths = resolve_agent(args.agent)
        report = generate_report(paths, report_date, args.save)
        print(report)

if __name__ == '__main__':
    main()
