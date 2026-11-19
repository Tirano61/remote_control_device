/*
 * Fault relay for physical tests of the /devices recovery (Prompts 35–36).
 *
 * Sits between a tablet and a real backend it never modifies:
 *
 *   tablet --(dev tunnel)--> 127.0.0.1:RELAY_PORT --> UPSTREAM (the backend)
 *
 * Everything passes through untouched unless a fault is armed on the control
 * port. The faults reproduce, byte for byte, what the backend itself would send:
 *
 *   rejectHandshakes n   the next n Socket.IO CONNECTs to /devices are answered
 *                        with the backend's DEVICE_AUTH_UNAUTHORIZED frame
 *                        (REALTIME.md, "Wire format") and not forwarded
 *   unavailableHandshakes n
 *                        the same, with the DEVICE_AUTH_UNAVAILABLE frame the
 *                        backend sends when its database fails
 *   legacyRejectHandshakes n
 *                        the same, with the bare `{"message":"Unauthorized"}`
 *                        of a backend older than the codes
 *   serverDisconnect     every open /devices socket receives `41/devices,`
 *                        (the namespace DISCONNECT that DevicePresenceService
 *                        .disconnectDevice produces) and is closed
 *   loginReject bool     POST /device-auth/login is answered with the exact
 *                        401 DEVICE_CREDENTIAL_REJECTED body, without reaching
 *                        the backend (nothing in the database changes)
 *   cutMs ms             drops every relayed connection and refuses new ones
 *   closeDevices         closes every open /devices WebSocket gracefully; behind
 *                        a dev tunnel the client notices at once, while a cut
 *                        only shows after the Engine.IO ping timeout
 *
 * Privacy: request and response bodies are never logged. A Device JWT is only
 * ever recorded as `tok#n`, the order in which this relay first saw it; the
 * mapping lives in memory and dies with the process.
 *
 * Needs the `ws` package (remote_control_backend's node_modules has it):
 *
 *   NODE_PATH=../remote_control_backend/node_modules node tool/realtime_harness/fault_relay.js
 *
 * Env: RELAY_PORT (3010), CTL_PORT (3011), UPSTREAM (http://127.0.0.1:3000).
 */
'use strict';

const http = require('http');
const crypto = require('crypto');
const { WebSocket, WebSocketServer } = require('ws');

const RELAY_PORT = Number(process.env.RELAY_PORT ?? 3010);
const CTL_PORT = Number(process.env.CTL_PORT ?? 3011);
const UPSTREAM = new URL(process.env.UPSTREAM ?? 'http://127.0.0.1:3000');

const REJECTION_BODY = JSON.stringify({
  statusCode: 401,
  code: 'DEVICE_CREDENTIAL_REJECTED',
  message: 'Invalid device credentials',
  error: 'Unauthorized',
});

// The exact CONNECT_ERROR frames of remote_control_backend (Prompt 33).
const REFUSALS = {
  rejectHandshakes: '44/devices,{"message":"Unauthorized","data":{"code":"DEVICE_AUTH_UNAUTHORIZED"}}',
  unavailableHandshakes: '44/devices,{"message":"Service unavailable","data":{"code":"DEVICE_AUTH_UNAVAILABLE"}}',
  legacyRejectHandshakes: '44/devices,{"message":"Unauthorized"}',
};

const faults = {
  rejectHandshakes: 0,
  unavailableHandshakes: 0,
  legacyRejectHandshakes: 0,
  loginReject: false,
  cutUntil: 0,
};
const events = [];
const t0 = Date.now();
const log = (e) => {
  const entry = { t: new Date().toISOString().slice(11, 23), ms: Date.now() - t0, ...e };
  events.push(entry);
  console.log(JSON.stringify(entry));
};

const tokens = new Map();
const label = (token) => {
  if (typeof token !== 'string' || token.length === 0) return 'none';
  const h = crypto.createHash('sha256').update(token).digest('hex');
  if (!tokens.has(h)) tokens.set(h, tokens.size + 1);
  return `tok#${tokens.get(h)}`;
};
const bearer = (headers) =>
  label(String(headers.authorization ?? '').replace(/^Bearer /, ''));

const cut = () => Date.now() < faults.cutUntil;
const liveSockets = new Set(); // raw TCP sockets of the relay server
const deviceSockets = new Set(); // { client, upstream } for /devices

// ------------------------------------------------------------------- HTTP

const server = http.createServer((req, res) => {
  if (cut()) {
    req.socket.destroy();
    return;
  }
  const isLogin = req.method === 'POST' && req.url.startsWith('/device-auth/login');

  if (isLogin && faults.loginReject) {
    req.resume(); // drain the credential, never read it
    req.on('end', () => {
      res.writeHead(401, { 'content-type': 'application/json; charset=utf-8' });
      res.end(REJECTION_BODY);
      log({ ev: 'http', method: req.method, path: req.url, status: 401, note: 'synthesised DEVICE_CREDENTIAL_REJECTED' });
    });
    return;
  }

  const headers = { ...req.headers, host: UPSTREAM.host };
  const up = http.request(
    { hostname: UPSTREAM.hostname, port: UPSTREAM.port, path: req.url, method: req.method, headers },
    (upRes) => {
      if (isLogin && upRes.statusCode === 200) {
        // Only to label the issued token; the body is forwarded unchanged.
        const chunks = [];
        upRes.on('data', (c) => chunks.push(c));
        upRes.on('end', () => {
          const body = Buffer.concat(chunks);
          let issued = 'unparsed';
          try {
            issued = label(JSON.parse(body.toString('utf8')).token);
          } catch (_) {
            /* forwarded as is */
          }
          res.writeHead(upRes.statusCode, upRes.headers);
          res.end(body);
          log({ ev: 'http', method: req.method, path: req.url, status: 200, issued });
        });
        return;
      }
      res.writeHead(upRes.statusCode, upRes.headers);
      upRes.pipe(res);
      log({ ev: 'http', method: req.method, path: req.url.split('?')[0], status: upRes.statusCode, auth: bearer(req.headers) });
    },
  );
  up.on('error', (e) => {
    res.writeHead(502);
    res.end();
    log({ ev: 'http', method: req.method, path: req.url, status: 502, error: e.code });
  });
  req.pipe(up);
});

server.on('connection', (s) => {
  liveSockets.add(s);
  s.on('close', () => liveSockets.delete(s));
});

// -------------------------------------------------------------- WebSocket

const wss = new WebSocketServer({ noServer: true });

server.on('upgrade', (req, socket, head) => {
  if (cut()) {
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (client) => relayWebSocket(req, client));
});

function relayWebSocket(req, client) {
  const target = `ws://${UPSTREAM.host}${req.url}`;
  const upstream = new WebSocket(target);
  const pair = { client, upstream, nsp: null, token: null };
  const pending = [];

  const closeBoth = () => {
    deviceSockets.delete(pair);
    if (client.readyState <= 1) client.close();
    if (upstream.readyState <= 1) upstream.close();
  };

  upstream.on('open', () => {
    for (const m of pending) upstream.send(m.data, { binary: m.isBinary });
    pending.length = 0;
  });
  upstream.on('message', (data, isBinary) => {
    const text = isBinary ? null : data.toString('utf8');
    if (text && pair.nsp === '/devices' && text.startsWith('40/devices,')) {
      deviceSockets.add(pair);
      log({ ev: 'handshake', token: pair.token, result: 'accepted by backend' });
    } else if (text && text.startsWith('44/devices,')) {
      log({ ev: 'handshake', token: pair.token, result: 'refused by backend' });
    } else if (text && text.startsWith('41/devices')) {
      log({ ev: 'server-disconnect', token: pair.token, by: 'backend' });
    }
    if (client.readyState === 1) client.send(data, { binary: isBinary });
  });
  upstream.on('close', closeBoth);
  upstream.on('error', closeBoth);

  client.on('message', (data, isBinary) => {
    const text = isBinary ? null : data.toString('utf8');
    if (text && text.startsWith('40/devices,')) {
      pair.nsp = '/devices';
      let token = null;
      try {
        token = JSON.parse(text.slice('40/devices,'.length)).token;
      } catch (_) {
        /* no auth object */
      }
      pair.token = label(token);
      const fault = Object.keys(REFUSALS).find((k) => faults[k] > 0);
      if (fault) {
        faults[fault]--;
        client.send(REFUSALS[fault]);
        log({ ev: 'handshake', token: pair.token, result: `refused by relay (${fault})`, left: faults[fault] });
        return; // never reaches the backend
      }
    }
    if (upstream.readyState === 1) upstream.send(data, { binary: isBinary });
    else pending.push({ data, isBinary });
  });
  client.on('close', () => {
    if (pair.nsp) log({ ev: 'socket-closed', token: pair.token });
    closeBoth();
  });
  client.on('error', closeBoth);
}

server.listen(RELAY_PORT, '127.0.0.1', () =>
  log({ ev: 'listening', relay: RELAY_PORT, ctl: CTL_PORT, upstream: UPSTREAM.origin }),
);

// ---------------------------------------------------------------- control

http
  .createServer((req, res) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      const reply = (code, obj) => {
        res.writeHead(code, { 'content-type': 'application/json' });
        res.end(JSON.stringify(obj));
      };
      try {
        const cmd = body ? JSON.parse(body) : {};
        if (req.url === '/log') return reply(200, { events, faults, openDeviceSockets: deviceSockets.size });
        if (req.url !== '/ctl') return reply(404, {});
        for (const k of Object.keys(REFUSALS)) if (typeof cmd[k] === 'number') faults[k] = cmd[k];
        if (typeof cmd.loginReject === 'boolean') faults.loginReject = cmd.loginReject;
        if (typeof cmd.cutMs === 'number') {
          faults.cutUntil = Date.now() + cmd.cutMs;
          for (const s of liveSockets) s.destroy();
          for (const p of deviceSockets) p.client.terminate();
        }
        if (cmd.closeDevices) {
          // A graceful WebSocket close, which the dev tunnel forwards: the
          // tablet sees a lost transport at once, instead of after the ~45 s
          // ping timeout that a TCP cut behind the tunnel costs.
          let n = 0;
          for (const p of [...deviceSockets]) {
            if (p.client.readyState === 1) {
              p.client.close(1001);
              n++;
            }
          }
          cmd.closed = n;
        }
        if (cmd.serverDisconnect) {
          let n = 0;
          for (const p of [...deviceSockets]) {
            if (p.client.readyState === 1) {
              p.client.send('41/devices,');
              n++;
              log({ ev: 'server-disconnect', token: p.token, by: 'relay' });
            }
            setTimeout(() => {
              if (p.client.readyState <= 1) p.client.close();
              if (p.upstream.readyState <= 1) p.upstream.close();
            }, 100);
          }
          cmd.disconnected = n;
        }
        log({ ev: 'ctl', ...cmd });
        reply(200, { ok: true, faults });
      } catch (e) {
        reply(500, { error: String(e && e.message) });
      }
    });
  })
  .listen(CTL_PORT, '127.0.0.1');
