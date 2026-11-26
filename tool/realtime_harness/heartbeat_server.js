/*
 * A bare Socket.IO server for the heartbeat integration test (Prompt 42):
 * the real Engine.IO heartbeat of socket.io 4.8.1 (the backend's version),
 * with a short interval so the real socket_io_client can be watched for a
 * few cycles in seconds. Nothing of remote_control_backend is loaded.
 *
 *   127.0.0.1:HEARTBEAT_PORT   socket.io, namespace /devices accepts anyone
 *
 * Put half_open_relay.js in front of it to hold traffic:
 *
 *   RELAY_PORT=3121 UPSTREAM_PORT=3120 CTL_PORT=3122 node half_open_relay.js
 *
 * Needs `socket.io@4.8.1` installed in a folder of its own (never from
 * remote_control_backend/node_modules):
 *
 *   NODE_PATH=<that folder>/node_modules node tool/realtime_harness/heartbeat_server.js
 *
 * Env: HEARTBEAT_PORT (3120), PING_INTERVAL_MS (2000), PING_TIMEOUT_MS (5000).
 */
'use strict';

const http = require('http');
const { Server } = require('socket.io');

const PORT = Number(process.env.HEARTBEAT_PORT ?? 3120);
const pingInterval = Number(process.env.PING_INTERVAL_MS ?? 2000);
const pingTimeout = Number(process.env.PING_TIMEOUT_MS ?? 5000);

const log = (event, fields = {}) =>
  console.log(JSON.stringify({ ms: Date.now(), event, ...fields }));

const server = http.createServer();
const io = new Server(server, { pingInterval, pingTimeout, transports: ['websocket'] });

io.of('/devices').on('connection', (socket) => {
  log('connected', { id: socket.id.slice(0, 6) });
  socket.conn.on('packet', (packet) => {
    if (packet.type === 'pong') log('pong-received', { id: socket.id.slice(0, 6) });
  });
  socket.conn.on('packetCreate', (packet) => {
    if (packet.type === 'ping') log('ping-sent', { id: socket.id.slice(0, 6) });
  });
  socket.on('disconnect', (reason) => log('disconnected', { id: socket.id.slice(0, 6), reason }));
});

server.listen(PORT, '127.0.0.1', () => log('listening', { port: PORT, pingInterval, pingTimeout }));
