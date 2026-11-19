# Realtime harness

An isolated backend for testing how `remote_control_device` recovers its
`/devices` Socket.IO connection. It is built from **the backend's own code**:
`DevicesGateway` with its namespace middleware, `DeviceAuthController`,
`DeviceAuthService`, `DeviceJwtStrategy`, `DevicesService` and presence. The
TypeORM repositories are replaced by in-memory doubles with fault injection.

It uses no PostgreSQL, no Neon and no shared backend. The device and its secret
are fictitious, and it records only the issue number of each token, never the
token itself.

```text
127.0.0.1:3100  TCP relay — what the Dart client talks to; it can be cut
127.0.0.1:3101  Nest app (HTTP + Socket.IO)
127.0.0.1:3102  control API: POST /ctl, POST /log, POST /reset
```

## Run

It needs the sibling checkout `../remote_control_backend` with its
`node_modules` installed. Set `BACKEND_SRC` to use another location.

```bash
BE=../remote_control_backend
NODE_PATH=$BE/node_modules TS_NODE_TRANSPILE_ONLY=1 TS_NODE_PROJECT=$BE/tsconfig.json \
  node $BE/node_modules/ts-node/dist/bin.js tool/realtime_harness/isolated_backend.ts
```

Then, in another shell:

```bash
REALTIME_HARNESS=1 flutter test test/integration/socket_reconnect_isolated_test.dart
```

Without `REALTIME_HARNESS=1` the integration test is skipped, so a plain
`flutter test` does not need the harness.

## Faults (`POST /ctl`, JSON body)

| Field | Effect |
|---|---|
| `rejectHandshakes: n` | the next *n* handshakes are refused by the auth step (`connect_error: Unauthorized`) |
| `dbFailHandshakes: n` | the next *n* handshakes hit a simulated PostgreSQL error inside the real `authorizePayload` |
| `dbDown: bool` | every repository call fails, so login answers `500` and the handshake answers `Unauthorized` |
| `tokenTtlSeconds: s \| null` | expiry of the tokens issued from now on |
| `cutMs: ms` | drops every relayed connection and refuses new ones for *ms* |
| `setActive: bool` | `DevicesService.update(isActive)`, the real admin path; deactivating closes the sockets (`io server disconnect`) |
| `serverDisconnect: true` | `DevicePresenceService.disconnectDevice` on a device that stays active |
