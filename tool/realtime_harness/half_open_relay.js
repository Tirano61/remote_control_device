/*
 * Half-open relay for the heartbeat watchdog tests (Prompt 42).
 *
 *   tablet --(dev tunnel)--> 127.0.0.1:RELAY_PORT --> 127.0.0.1:UPSTREAM_PORT
 *
 * A plain TCP relay. While a direction is blocked, everything that enters it is
 * HELD: data, FIN and RST alike. Neither end gets an error or a close; for TCP
 * the connection is alive and only the Engine.IO heartbeat can notice that
 * nothing arrives. That is a network that stops delivering (Wi-Fi gone
 * without a word, a NAT that forgot the mapping, a firewall dropping) — the
 * case that socket_io_client only notices after `pingInterval + pingTimeout`.
 * When the block is lifted the held bytes are delivered in order, as TCP
 * would retransmit them; a close that happened meanwhile arrives then.
 * Connections opened during a block are held in the blocked directions too.
 *
 *   toServer   what the tablet sends (its PONGs, its events, its requests)
 *   toClient   what the backend sends (its PINGs, its events, its close)
 *
 * Same model as remote_control_backend test/support/half-open-relay.ts, which
 * measured the backend side in its Prompt 36.
 *
 * Observation only, never content: for every WebSocket it recognises it logs
 * the Engine.IO handshake values (pingInterval/pingTimeout, not the sid), each
 * PING and PONG it DELIVERS (the instant the other end receives it), the
 * Socket.IO event NAMES and close frames. Payloads, SDP, ICE, tokens and
 * HTTP bodies are never logged; HTTP requests are logged as method + path
 * without the query string.
 *
 * Control (127.0.0.1:CTL_PORT, POST /ctl, JSON):
 *
 *   {"block": "both" | "toServer" | "toClient", "ms": 15000}
 *                       block, and lift it after ms (omit ms: until unblock)
 *   {"unblock": true}   lift every block and deliver what was held
 *   {"closeAll": true}  end every relayed connection gracefully (FIN)
 *   GET /state          blocked directions and open connections
 *
 * Every log line is JSON with `ms` (PC clock, epoch milliseconds).
 *
 *   node tool/realtime_harness/half_open_relay.js
 *
 * Env: RELAY_PORT (3010), UPSTREAM_PORT (3200), CTL_PORT (3011). No packages.
 */
'use strict';

const net = require('net');
const http = require('http');

const RELAY_PORT = Number(process.env.RELAY_PORT ?? 3010);
const UPSTREAM_PORT = Number(process.env.UPSTREAM_PORT ?? 3200);
const CTL_PORT = Number(process.env.CTL_PORT ?? 3011);

const END = Symbol('end');
const DESTROY = Symbol('destroy');
const DIRECTIONS = ['toServer', 'toClient'];

const blocked = { toServer: false, toClient: false };
let unblockTimer = null;
const pairs = new Set();
let nextId = 1;

function log(event, fields = {}) {
  console.log(JSON.stringify({ ms: Date.now(), t: new Date().toISOString(), event, ...fields }));
}

/** Incremental WebSocket frame reader for one direction. */
class FrameReader {
  constructor(onFrame) {
    this.buffer = Buffer.alloc(0);
    this.onFrame = onFrame;
  }

  push(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      const b = this.buffer;
      if (b.length < 2) return;
      const opcode = b[0] & 0x0f;
      const masked = (b[1] & 0x80) !== 0;
      let length = b[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (b.length < 4) return;
        length = b.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (b.length < 10) return;
        length = Number(b.readBigUInt64BE(2));
        offset = 10;
      }
      const maskOffset = offset;
      if (masked) offset += 4;
      if (b.length < offset + length) return;
      let payload = b.subarray(offset, offset + length);
      if (masked) {
        const mask = b.subarray(maskOffset, maskOffset + 4);
        payload = Buffer.from(payload.map((byte, i) => byte ^ mask[i % 4]));
      }
      this.buffer = b.subarray(offset + length);
      this.onFrame(opcode, payload);
    }
  }
}

/** What an Engine.IO / Socket.IO text frame is, without its content. */
function describe(text) {
  if (text === '2') return { kind: 'PING' };
  if (text === '3') return { kind: 'PONG' };
  if (text.startsWith('0{')) {
    try {
      const open = JSON.parse(text.slice(1));
      return { kind: 'EIO_OPEN', pingInterval: open.pingInterval, pingTimeout: open.pingTimeout };
    } catch {
      return { kind: 'EIO_OPEN' };
    }
  }
  if (text === '1') return { kind: 'EIO_CLOSE' };
  // Socket.IO over Engine.IO "message" (4): 40 connect, 41 disconnect,
  // 42 event, 43 ack, 44 connect_error. Only the namespace and event name.
  const m = /^4([0-6])(\/[^,]*)?,?(\d*)(\[\s*"([^"]*)")?/.exec(text);
  if (!m) return { kind: 'OTHER' };
  const type = { 0: 'CONNECT', 1: 'DISCONNECT', 2: 'EVENT', 3: 'ACK', 4: 'CONNECT_ERROR' }[m[1]] ?? `SIO${m[1]}`;
  const out = { kind: type, nsp: m[2] ?? '/' };
  if (type === 'EVENT' && m[5] !== undefined) out.name = m[5];
  return out;
}

class Pair {
  constructor(client) {
    this.id = nextId++;
    this.client = client;
    this.upstream = net.connect({ host: '127.0.0.1', port: UPSTREAM_PORT, allowHalfOpen: true });
    this.held = { toServer: [], toClient: [] };
    this.kind = 'tcp';
    this.sawRequest = false;
    this.upgraded = false;
    this.readers = { toServer: null, toClient: null };
    pairs.add(this);

    client.on('data', (d) => this.forward('toServer', d));
    this.upstream.on('data', (d) => this.forward('toClient', d));
    client.on('end', () => this.forward('toServer', END));
    this.upstream.on('end', () => this.forward('toClient', END));
    client.on('error', () => this.forward('toServer', DESTROY));
    this.upstream.on('error', () => this.forward('toClient', DESTROY));
    client.on('close', () => this.closed('client'));
    this.upstream.on('close', () => this.closed('upstream'));
  }

  forward(direction, chunk) {
    if (blocked[direction] || this.held[direction].length > 0) {
      this.held[direction].push(chunk);
      return;
    }
    this.deliver(direction, chunk);
  }

  flush(direction) {
    while (!blocked[direction] && this.held[direction].length > 0) {
      this.deliver(direction, this.held[direction].shift());
    }
  }

  deliver(direction, chunk) {
    const target = direction === 'toServer' ? this.upstream : this.client;
    if (chunk === END) {
      log('fin', { pair: this.id, direction, ws: this.upgraded });
      target.end();
      return;
    }
    if (chunk === DESTROY) {
      log('reset', { pair: this.id, direction, ws: this.upgraded });
      target.destroy();
      return;
    }
    this.inspect(direction, chunk);
    if (!target.destroyed) target.write(chunk);
  }

  inspect(direction, chunk) {
    if (direction === 'toServer' && !this.sawRequest) {
      this.sawRequest = true;
      const line = chunk.toString('latin1').split('\r\n', 1)[0];
      const m = /^([A-Z]+) ([^ ?]*)/.exec(line);
      if (m) {
        this.kind = /upgrade: websocket/i.test(chunk.toString('latin1')) ? 'ws' : 'http';
        log('request', { pair: this.id, method: m[1], path: m[2], kind: this.kind });
      }
      return;
    }
    if (this.kind === 'http' && direction === 'toServer') {
      // Keep-alive: a later request on the same connection.
      const m = /^([A-Z]+) ([^ ?]*) HTTP\/1\.1/.exec(chunk.toString('latin1', 0, 200));
      if (m) log('request', { pair: this.id, method: m[1], path: m[2], kind: 'http' });
      return;
    }
    if (this.kind === 'http' && direction === 'toClient') {
      const m = /^HTTP\/1\.1 (\d{3})/.exec(chunk.toString('latin1', 0, 20));
      if (m) log('response', { pair: this.id, status: Number(m[1]) });
      return;
    }
    if (this.kind !== 'ws') return;
    if (!this.upgraded) {
      if (direction === 'toClient' && /^HTTP\/1\.1 101/.test(chunk.toString('latin1', 0, 20))) {
        this.upgraded = true;
        log('ws-upgraded', { pair: this.id });
        for (const d of DIRECTIONS) {
          this.readers[d] = new FrameReader((opcode, payload) => this.frame(d, opcode, payload));
        }
        const headerEnd = chunk.indexOf('\r\n\r\n');
        if (headerEnd >= 0 && headerEnd + 4 < chunk.length) {
          this.readers.toClient.push(chunk.subarray(headerEnd + 4));
        }
      }
      return;
    }
    this.readers[direction].push(chunk);
  }

  frame(direction, opcode, payload) {
    if (opcode === 8) {
      log('ws-close-frame', { pair: this.id, direction, code: payload.length >= 2 ? payload.readUInt16BE(0) : null });
      return;
    }
    if (opcode !== 1) return;
    const what = describe(payload.toString('utf8'));
    log('frame', { pair: this.id, direction, ...what });
  }

  closed(side) {
    if (!pairs.has(this)) return;
    if (this.client.destroyed && this.upstream.destroyed) {
      pairs.delete(this);
      log('pair-closed', { pair: this.id, side, ws: this.upgraded });
    }
  }
}

function setBlock(directions, ms) {
  for (const d of DIRECTIONS) blocked[d] = directions.includes(d);
  if (unblockTimer) clearTimeout(unblockTimer);
  unblockTimer = null;
  log('block', { toServer: blocked.toServer, toClient: blocked.toClient, forMs: ms ?? null, open: pairs.size });
  if (ms) unblockTimer = setTimeout(unblock, ms);
}

function unblock() {
  if (unblockTimer) clearTimeout(unblockTimer);
  unblockTimer = null;
  blocked.toServer = false;
  blocked.toClient = false;
  const held = [...pairs].reduce((n, p) => n + p.held.toServer.length + p.held.toClient.length, 0);
  log('unblock', { heldChunks: held, open: pairs.size });
  for (const pair of [...pairs]) {
    for (const d of DIRECTIONS) pair.flush(d);
  }
}

const relay = net.createServer({ allowHalfOpen: true }, (client) => {
  const pair = new Pair(client);
  log('connection', { pair: pair.id, blocked: { ...blocked } });
});
relay.listen(RELAY_PORT, '127.0.0.1', () =>
  log('listening', { relay: RELAY_PORT, upstream: UPSTREAM_PORT, ctl: CTL_PORT }),
);

http
  .createServer((req, res) => {
    const reply = (status, body) => {
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(JSON.stringify(body));
    };
    if (req.method === 'GET' && req.url === '/state') {
      return reply(200, { blocked, open: [...pairs].map((p) => ({ id: p.id, kind: p.kind, ws: p.upgraded })) });
    }
    if (req.method !== 'POST' || req.url !== '/ctl') return reply(404, {});
    let body = '';
    req.on('data', (d) => (body += d));
    req.on('end', () => {
      let cmd;
      try {
        cmd = JSON.parse(body || '{}');
      } catch {
        return reply(400, { error: 'json' });
      }
      if (cmd.block) {
        const directions = cmd.block === 'both' ? DIRECTIONS : [cmd.block];
        if (!directions.every((d) => DIRECTIONS.includes(d))) return reply(400, { error: 'block' });
        setBlock(directions, cmd.ms);
      } else if (cmd.unblock) {
        unblock();
      } else if (cmd.closeAll) {
        log('close-all', { open: pairs.size });
        for (const pair of [...pairs]) {
          pair.client.end();
          pair.upstream.end();
        }
      } else {
        return reply(400, { error: 'unknown' });
      }
      reply(200, { ok: true, ms: Date.now(), blocked });
    });
  })
  .listen(CTL_PORT, '127.0.0.1');
