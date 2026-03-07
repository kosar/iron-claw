#!/usr/bin/env node
/**
 * Test OpenClaw gateway over WebSocket (for WebSocket-only gateway images).
 * Sends one user message, collects assistant reply, prints result and exits.
 *
 * Usage:
 *   node scripts/test-gateway-ws.js [message]
 *   VERBOSE=1 node scripts/test-gateway-ws.js [message]   # log frames
 *   OPENCLAW_GATEWAY_WS=ws://host:port node scripts/test-gateway-ws.js
 *
 * Default message: "Reply with exactly: IronClaw is working."
 *
 * Requires: npm install ws   (from repo root: npm install ws)
 * Reads: OPENCLAW_GATEWAY_TOKEN from .env (same as test-gateway-http.sh)
 *
 * If you get "socket hang up" with no frames, the gateway image may use a
 * different protocol version; use Telegram or the CLI to test instead.
 */

const WebSocket = require('ws');
const fs = require('fs');
const path = require('path');

const GATEWAY_WS = process.env.OPENCLAW_GATEWAY_WS || 'ws://127.0.0.1:18789';
const PROJECT_ROOT = path.resolve(__dirname, '..');
const ENV_PATH = path.join(PROJECT_ROOT, '.env');
const VERBOSE = process.env.VERBOSE === '1' || process.argv.includes('--verbose');

function readToken() {
  if (!fs.existsSync(ENV_PATH)) {
    console.error('No .env file. Create one with OPENCLAW_GATEWAY_TOKEN=your_token');
    process.exit(1);
  }
  const line = fs.readFileSync(ENV_PATH, 'utf8')
    .split('\n')
    .find(l => /^OPENCLAW_GATEWAY_TOKEN=/.test(l));
  if (!line) {
    console.error('OPENCLAW_GATEWAY_TOKEN not set in .env');
    process.exit(1);
  }
  const token = line.replace(/^OPENCLAW_GATEWAY_TOKEN=/, '').replace(/^["']|["']$/g, '').trim();
  if (!token) {
    console.error('OPENCLAW_GATEWAY_TOKEN is empty in .env');
    process.exit(1);
  }
  return token;
}

function main() {
  const message = process.argv[2] || 'Reply with exactly: IronClaw is working.';
  const token = readToken();

  return new Promise((resolve, reject) => {
    const ws = new WebSocket(GATEWAY_WS, {
      handshakeTimeout: 10000,
    });

    let connectReqId = null;
    let agentReqId = null;
    let runId = null;
    const assistantParts = [];
    let done = false;
    let challenge = null;
    let connectSent = false;
    const timeout = setTimeout(() => {
      if (done) return;
      done = true;
      ws.close();
      if (assistantParts.length) {
        console.log('\n--- (timeout; partial reply above) ---');
        resolve(0);
      } else {
        console.error('Timeout waiting for assistant reply.');
        resolve(1);
      }
    }, 120000); // 2 min for Ollama/OpenAI

    function sendConnect() {
      if (connectSent) return;
      connectSent = true;
      connectReqId = 'connect-' + Date.now();
      const deviceId = 'test-device-' + Math.random().toString(36).slice(2, 12);
      const params = {
        minProtocol: 1,
        maxProtocol: 3,
        client: { id: 'test-gateway-ws', version: '1.0.0', platform: 'node', mode: 'operator' },
        role: 'operator',
        scopes: ['operator.read', 'operator.write'],
        caps: [],
        commands: [],
        permissions: {},
        auth: { token },
        locale: 'en-US',
        userAgent: 'test-gateway-ws/1.0',
        device: {
          id: deviceId,
          publicKey: '',
          signature: '',
          signedAt: challenge ? (challenge.ts || Date.now()) : Date.now(),
          nonce: challenge ? (challenge.nonce || '') : '',
        },
      };
      if (VERBOSE) console.error('[ws] sending connect...');
      ws.send(JSON.stringify({ type: 'req', id: connectReqId, method: 'connect', params }));
    }

    ws.on('open', () => {
      if (VERBOSE) console.error('[ws open]');
      sendConnect();
    });

    ws.on('message', (data) => {
      const raw = data.toString();
      if (VERBOSE) console.error('[recv raw]', raw.slice(0, 400));
      let msg;
      try {
        msg = JSON.parse(raw);
      } catch {
        return;
      }
      if (VERBOSE) console.error('[recv]', JSON.stringify(msg).slice(0, 300));

      if (msg.type === 'event' && msg.event === 'connect.challenge') {
        challenge = msg.payload || {};
        if (VERBOSE) console.error('[ws] got challenge, sending connect with nonce');
        connectSent = false;
        sendConnect();
        return;
      }

      if (msg.type === 'res' && msg.id === connectReqId) {
        if (!msg.ok) {
          console.error('Connect failed:', msg.error || msg.payload);
          done = true;
          clearTimeout(timeout);
          ws.close();
          return resolve(1);
        }
        agentReqId = 'agent-' + Date.now();
        ws.send(JSON.stringify({
          type: 'req',
          id: agentReqId,
          method: 'agent',
          params: {
            agentId: 'main',
            sessionKey: 'main',
            message: { role: 'user', content: message },
            idempotencyKey: 'test-' + Date.now(),
          },
        }));
        return;
      }

      if (msg.type === 'res' && msg.id === agentReqId) {
        if (!msg.ok) {
          console.error('Agent request failed:', msg.error || msg.payload);
          done = true;
          clearTimeout(timeout);
          ws.close();
          return resolve(1);
        }
        runId = msg.payload?.runId;
        return;
      }

      if (msg.type === 'event' && msg.payload) {
        const p = msg.payload;
        if (msg.event === 'stream' && p.stream === 'assistant' && p.delta) {
          process.stdout.write(p.delta);
          assistantParts.push(p.delta);
        }
        if (msg.event === 'stream' && p.stream === 'lifecycle' && (p.phase === 'end' || p.phase === 'error')) {
          if (!done) {
            done = true;
            clearTimeout(timeout);
            if (assistantParts.length) {
              console.log('\n---');
              console.log('Gateway and agent responded successfully.');
            } else if (p.phase === 'error') {
              console.error('Agent run error:', p);
              resolve(1);
            }
            ws.close();
            resolve(p.phase === 'error' ? 1 : 0);
          }
        }
      }
    });

    ws.on('error', (err) => {
      if (!done) {
        done = true;
        clearTimeout(timeout);
        console.error('WebSocket error:', err.message);
        resolve(1);
      }
    });

    ws.on('close', (code, reason) => {
      if (VERBOSE) console.error('[ws close] code=%s reason=%s', code, reason?.toString() || '');
      clearTimeout(timeout);
      if (!done) {
        done = true;
        if (assistantParts.length) resolve(0);
        else resolve(1);
      }
    });
  });
}

main()
  .then((code) => process.exit(code))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
