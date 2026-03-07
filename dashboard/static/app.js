(function () {
  const BASE = '';
  let refreshTimer = null;
  let agentList = ['pibot'];

  function el(id) { return document.getElementById(id); }
  function escapeHtml(s) {
    if (s == null) return '';
    const div = document.createElement('div');
    div.textContent = s;
    return div.innerHTML;
  }

  function fetchJson(path) {
    return fetch(BASE + path).then(r => r.json()).catch(() => ({ ok: false, error: 'fetch failed' }));
  }

  function getPrimaryAgent(agents) {
    if (!agents || !agents.length) return null;
    var running = agents.find(function (a) { return (a.status || '').toLowerCase().includes('running'); });
    return running ? running.name : agents[0].name;
  }

  function isAgentRunning(agents, name) {
    var a = agents.find(function (x) { return x.name === name; });
    return a && (a.status || '').toLowerCase().includes('running');
  }

  function renderAgents(data) {
    const node = el('agents');
    if (!data.ok || !data.agents || !data.agents.length) {
      node.textContent = data.error || 'No agents';
      node.className = 'card error';
      return;
    }
    node.className = 'card';
    agentList = data.agents.map(a => a.name);
    let html = '<table><thead><tr><th>Agent</th><th>Port</th><th>RAM</th><th>CPUs</th><th>Container</th><th>Status</th><th>Control UI</th></tr></thead><tbody>';
    data.agents.forEach(a => {
      const statusClass = (a.status || '').toLowerCase().includes('running') ? 'status-ok' : 'status-err';
      // Control UI = OpenClaw gateway for this agent (same host as dashboard, agent port, root path)
      const port = (a.port && String(a.port).trim()) || '';
      const host = window.location.hostname;
      const controlUrl = port ? ('http://' + host + ':' + port + '/') : '';
      const controlCell = controlUrl
        ? '<a href="' + controlUrl + '" target="_blank" rel="noopener">Open</a>'
        : '—';
      html += '<tr><td>' + escapeHtml(a.name) + '</td><td>' + escapeHtml(a.port) + '</td><td>' + escapeHtml(a.mem) + '</td><td>' + escapeHtml(a.cpus) + '</td><td>' + escapeHtml(a.container) + '</td><td class="' + statusClass + '">' + escapeHtml(a.status + (a.health ? ' (' + a.health + ')' : '')) + '</td><td>' + controlCell + '</td></tr>';
    });
    html += '</tbody></table>';
    node.innerHTML = html;
  }

  function fillAgentSelects(agents, primaryAgent) {
    ['logAgent', 'failAgent', 'usageAgent', 'learningAgent'].forEach(id => {
      const sel = el(id);
      if (!sel || !agentList.length) return;
      const cur = sel.value;
      sel.innerHTML = agentList.map(a => '<option value="' + escapeHtml(a) + '">' + escapeHtml(a) + '</option>').join('');
      if (primaryAgent && (!cur || !agentList.includes(cur) || (agents && !isAgentRunning(agents, cur)))) {
        sel.value = primaryAgent;
      } else if (agentList.includes(cur)) {
        sel.value = cur;
      } else {
        sel.value = agentList[0];
      }
    });
  }

  function renderLearning(data) {
    const node = el('learning');
    if (!data || data.ok !== true) {
      node.textContent = (data && data.error) || '—';
      node.className = 'card error';
      return;
    }

    node.className = 'card learning-card';
    if (!data.enabled) {
      const reason = data.reason || 'learning data not available';
      node.innerHTML = '<div class="learning-muted">No learning data yet for ' + escapeHtml(data.agent || '') + ': ' + escapeHtml(reason) + '.</div>';
      return;
    }

    const s = data.summary || {};
    const sev = s.severity_counts || {};
    const recent = Array.isArray(data.recent) ? data.recent : [];
    const history = Array.isArray(data.history) ? data.history : [];
    const latestSignal = data.latestSignal || '';

    let html = '';
    html += '<div class="learning-summary">';
    html += '<div><strong>Runs tracked:</strong> ' + escapeHtml(String(s.count || 0)) + '</div>';
    html += '<div><strong>Avg:</strong> ' + escapeHtml(String(s.avg_overall != null ? s.avg_overall : '—')) +
            ' | <strong>Best:</strong> ' + escapeHtml(String(s.best_overall != null ? s.best_overall : '—')) +
            ' | <strong>Worst:</strong> ' + escapeHtml(String(s.worst_overall != null ? s.worst_overall : '—')) + '</div>';
    html += '<div><strong>From start:</strong> ' + escapeHtml(String(s.delta_from_start != null ? s.delta_from_start : '—')) +
            ' (' + escapeHtml(String(s.direction_from_start || 'flat')) + ')' + '</div>';
    html += '<div><strong>Severity counts:</strong> excellent ' + escapeHtml(String(sev.excellent || 0)) +
            ', healthy ' + escapeHtml(String(sev.healthy || 0)) +
            ', watch ' + escapeHtml(String(sev.watch || 0)) +
            ', action ' + escapeHtml(String(sev.action || 0)) + '</div>';
    if (latestSignal) {
      html += '<div class="learning-signal"><strong>Latest signal:</strong> ' + escapeHtml(latestSignal) + '</div>';
    }
    html += '</div>';

    html += '<div class="learning-subhead">Recent results (most recent first, concise)</div>';
    if (!recent.length) {
      html += '<div class="learning-muted">No recent learning results.</div>';
    } else {
      html += '<table><thead><tr><th>Time</th><th>#</th><th>Overall</th><th>Severity</th><th>Short dir</th><th>Long dir</th></tr></thead><tbody>';
      recent.forEach(r => {
        html += '<tr>' +
          '<td>' + escapeHtml(String((r.timestamp || '').replace('T', ' ').replace('Z', ''))) + '</td>' +
          '<td>' + escapeHtml(String(r.run_index || '')) + '</td>' +
          '<td>' + escapeHtml(String(r.overall != null ? r.overall : '')) + '</td>' +
          '<td>' + escapeHtml(String(r.severity || '')) + '</td>' +
          '<td>' + escapeHtml(String(r.short_direction || '')) + '</td>' +
          '<td>' + escapeHtml(String(r.long_direction || '')) + '</td>' +
          '</tr>';
      });
      html += '</tbody></table>';
    }

    html += '<div class="learning-subhead">Historical values (oldest → newest, full timeline)</div>';
    if (!history.length) {
      html += '<div class="learning-muted">No historical timeline available.</div>';
    } else {
      html += '<div class="learning-history-box"><table><thead><tr>' +
              '<th>#</th><th>Time</th><th>Overall</th><th>Reliab.</th><th>Eff.</th><th>Hyg.</th><th>Severity</th><th>Short Δ</th><th>Long Δ</th><th>Uptake</th>' +
              '</tr></thead><tbody>';
      history.forEach(r => {
        html += '<tr>' +
          '<td>' + escapeHtml(String(r.run_index || '')) + '</td>' +
          '<td>' + escapeHtml(String((r.timestamp || '').replace('T', ' ').replace('Z', ''))) + '</td>' +
          '<td>' + escapeHtml(String(r.overall != null ? r.overall : '')) + '</td>' +
          '<td>' + escapeHtml(String(r.reliability != null ? r.reliability : '')) + '</td>' +
          '<td>' + escapeHtml(String(r.efficiency != null ? r.efficiency : '')) + '</td>' +
          '<td>' + escapeHtml(String(r.hygiene != null ? r.hygiene : '')) + '</td>' +
          '<td>' + escapeHtml(String(r.severity || '')) + '</td>' +
          '<td>' + escapeHtml(String(r.short_delta != null ? r.short_delta : '')) + '</td>' +
          '<td>' + escapeHtml(String(r.long_delta != null ? r.long_delta : '')) + '</td>' +
          '<td>' + escapeHtml(String(r.feedback_uptake_rate != null ? r.feedback_uptake_rate : '')) + '</td>' +
          '</tr>';
      });
      html += '</tbody></table></div>';
    }

    node.innerHTML = html;
  }

  function renderBridges(data) {
    const node = el('bridges');
    if (!data.ok || !data.bridges) {
      node.textContent = data.error || '—';
      node.className = 'card ' + (data.ok ? '' : 'error');
      return;
    }
    node.className = 'card';
    node.innerHTML = data.bridges.map(b => {
      const cls = b.listening ? (b.reachable ? 'status-ok' : 'status-warn') : 'status-err';
      return '<div class="bridge-row"><span class="bridge-name">' + escapeHtml(b.name) + ' :' + b.port + '</span><span class="' + cls + '">' + (b.listening ? (b.reachable ? 'reachable' : 'listening') : 'down') + '</span><span class="bridge-detail">' + escapeHtml(b.detail || '') + '</span></div>';
    }).join('');
  }

  function renderGateway(data) {
    const node = el('gateway');
    if (!data) { node.textContent = '—'; node.className = 'card'; return; }
    const ok = data.ok === true;
    node.className = 'card ' + (ok ? 'status-ok' : 'error');
    var msg = ok ? (data.message || 'OK') : (data.error || data.message || 'fail');
    if (!ok && (data.statusCode === '000' || data.statusCode === '')) {
      msg = 'Gateway not responding — is the agent container running?';
    }
    node.textContent = (data.agent ? data.agent + ': ' : '') + msg;
  }

  function renderRfid(data) {
    const node = el('rfid');
    if (!data) { node.textContent = '—'; node.className = 'card'; return; }
    node.className = 'card';
    const run = data.daemonRunning === true;
    const scan = data.lastScan;
    let html = 'Daemon: <span class="' + (run ? 'status-ok' : 'status-err') + '">' + (run ? 'running' : 'not running') + '</span>';
    if (data.error && !run) html += ' <span class="status-err">(' + escapeHtml(data.error) + ')</span>';
    if (scan && scan.timestamp_iso) {
      html += '<br>Last scan: <strong>' + escapeHtml(scan.tag_id || scan.uid_hex || '?') + '</strong> at ' + escapeHtml(scan.timestamp_iso);
    } else {
      html += '<br>Last scan: none';
    }
    node.innerHTML = html;
  }

  function renderChannels(data) {
    const node = el('channels');
    if (!data) { node.textContent = '—'; node.className = 'card channels-card'; return; }
    node.className = 'card channels-card';
    if (data.error && !data.telegram) {
      node.innerHTML = '<span class="channels-label">Agent: ' + escapeHtml(data.agent || '') + '</span><br><span class="status-err">' + escapeHtml(data.error) + '</span>';
      return;
    }
    if (data.telegram && data.telegram.username) {
      var u = data.telegram.username;
      node.innerHTML = '<span class="channels-label">Telegram bot (the @name in Telegram)</span><div class="telegram-handle"><span class="at">@</span>' + escapeHtml(u) + '</div>' + (data.telegram.firstName ? '<span class="channels-label">' + escapeHtml(data.telegram.firstName) + '</span>' : '');
    } else {
      node.innerHTML = '<span class="channels-label">Agent: ' + escapeHtml(data.agent || '') + '</span><br><span class="channels-label">No Telegram bot configured</span>';
    }
  }

  function renderDocker(data) {
    const node = el('docker');
    if (!data.ok || !data.containers) {
      node.textContent = data.error || (data.containers && !data.containers.length ? 'No ironclaw containers' : '—');
      node.className = 'card ' + (data.ok ? '' : 'error');
      return;
    }
    node.className = 'card';
    node.innerHTML = '<table><thead><tr><th>Container</th><th>Status</th><th>Created</th></tr></thead><tbody>' + data.containers.map(c => '<tr><td>' + escapeHtml(c.name) + '</td><td>' + escapeHtml(c.status) + '</td><td>' + escapeHtml(c.created) + '</td></tr>').join('') + '</tbody></table>';
  }

  function renderLogs(data) {
    const node = el('logs');
    if (!data.ok) {
      node.textContent = data.error || '—';
      node.className = 'card log-box error';
      return;
    }
    node.className = 'card log-box';
    if (!data.lines || !data.lines.length) {
      node.textContent = 'No log lines';
      return;
    }
    node.textContent = data.lines.map(l => (l.time ? l.time + ' ' : '') + (l.level ? '[' + l.level + '] ' : '') + (l.msg || '')).join('\n');
  }

  function renderFailures(data) {
    const node = el('failures');
    if (!data || !data.ok) {
      node.textContent = (data && data.error) || '—';
      node.className = 'card ' + ((data && data.ok) ? '' : 'error');
      return;
    }
    node.className = 'card';
    const s = data.summary || {};
    let html = 'Summary: auth ' + (s.auth || 0) + ', tool ' + (s.tool || 0) + ', network ' + (s.network || 0) + ', provider ' + (s.provider || 0) + ', error ' + (s.error || 0) + ', other ' + (s.other || 0);
    if (data.sample && data.sample.length) {
      html += '<br><br>Sample:<br>' + data.sample.map(x => escapeHtml((x.time || '') + ' [' + (x.cat || '') + '] ' + (x.msg || ''))).join('<br>');
    }
    node.innerHTML = html;
  }

  function renderUsage(data) {
    const node = el('usage');
    if (!data || !data.ok) {
      node.textContent = (data && data.error) || '—';
      node.className = 'card ' + ((data && data.ok) ? '' : 'error');
      return;
    }
    node.className = 'card';
    node.textContent = 'Turns: ' + (data.turns || 0) + ', Tokens in: ' + (data.tokensIn || 0) + ', Tokens out: ' + (data.tokensOut || 0) + (data.costUsd != null ? ', Est. cost (USD): ' + data.costUsd : '');
  }

  function refreshAll() {
    const n = el('logN') && el('logN').value ? el('logN').value : '30';

    fetchJson('/api/agents').then(function (agents) {
      var primary = (agents.ok && agents.agents && agents.agents.length) ? getPrimaryAgent(agents.agents) : 'pibot';
      renderAgents(agents);
      fillAgentSelects(agents.ok ? agents.agents : null, primary);
      var selected = (el('logAgent') && el('logAgent').value) ? el('logAgent').value : primary;
      var selectedLearning = (el('learningAgent') && el('learningAgent').value) ? el('learningAgent').value : selected;
      return Promise.all([
        Promise.resolve(agents),
        fetchJson('/api/bridges'),
        fetchJson('/api/docker'),
        fetchJson('/api/logs?agent=' + encodeURIComponent(selected) + '&n=' + encodeURIComponent(n)),
        fetchJson('/api/failures?agent=' + encodeURIComponent(selected)),
        fetchJson('/api/usage?agent=' + encodeURIComponent(selected)),
        fetchJson('/api/gateway?agent=' + encodeURIComponent(selected)),
        fetchJson('/api/channels?agent=' + encodeURIComponent(selected)),
        fetchJson('/api/rfid?agent=' + encodeURIComponent(selected)),
        fetchJson('/api/learning?agent=' + encodeURIComponent(selectedLearning)),
      ]);
    }).then(function (results) {
      var agents = results[0], bridges = results[1], docker = results[2], logs = results[3], failures = results[4], usage = results[5], gw = results[6], channels = results[7], rfid = results[8], learning = results[9];
      renderBridges(bridges);
      renderDocker(docker);
      renderLogs(logs);
      renderFailures(failures);
      renderUsage(usage);
      renderGateway(gw);
      renderChannels(channels);
      renderRfid(rfid);
      renderLearning(learning);
    }).catch(function () {});

    el('lastUpdate').textContent = 'Updated ' + new Date().toLocaleTimeString();
  }

  el('refreshBtn').addEventListener('click', () => { refreshAll(); });
  el('autoRefresh').addEventListener('change', function() {
    if (this.checked) {
      refreshTimer = setInterval(refreshAll, 30000);
      refreshAll();
    } else {
      if (refreshTimer) clearInterval(refreshTimer);
      refreshTimer = null;
    }
  });
  el('logAgent').addEventListener('change', refreshAll);
  el('failAgent').addEventListener('change', refreshAll);
  el('usageAgent').addEventListener('change', refreshAll);
  el('learningAgent').addEventListener('change', refreshAll);
  el('logN').addEventListener('change', refreshAll);

  el('hostInfo').textContent = window.location.hostname + ':' + (window.location.port || '80');
  refreshAll();
  if (el('autoRefresh').checked) refreshTimer = setInterval(refreshAll, 30000);
})();
