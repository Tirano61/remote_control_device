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
`node_modules` installed. Set `BACKEND_SRC` to use another location. When
that checkout is being served by `nest start --watch`, prefer an exported
copy, which nothing watches:

```bash
git -C ../remote_control_backend archive main src tsconfig.json | tar -x -C /tmp/be
BACKEND_SRC=/tmp/be/src TS_NODE_PROJECT=/tmp/be/tsconfig.json ...
```

Each `handshake` entry of `/log` carries `code`: the `data.code` the
backend's own `classifyHandshakeFailure` gives that failure.

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
| `rejectHandshakes: n` | the next *n* handshakes are refused by the auth step with an `UnauthorizedException`, so the gateway answers `DEVICE_AUTH_UNAUTHORIZED` |
| `dbFailHandshakes: n` | the next *n* handshakes hit a simulated PostgreSQL error inside the real `authorizePayload`, so the gateway answers `DEVICE_AUTH_UNAVAILABLE` |
| `dbDown: bool` | every repository call fails, so login answers `500` and the handshake answers `DEVICE_AUTH_UNAVAILABLE` (an expired token is still `DEVICE_AUTH_UNAUTHORIZED`: expiry is checked first) |
| `tokenTtlSeconds: s \| null` | expiry of the tokens issued from now on |
| `cutMs: ms` | drops every relayed connection and refuses new ones for *ms* |
| `setActive: bool` | `DevicesService.update(isActive)`, the real admin path; deactivating closes the sockets (`io server disconnect`) |
| `serverDisconnect: true` | `DevicePresenceService.disconnectDevice` on a device that stays active |

## Fault relay for physical tests

`fault_relay.js` sits between a tablet and a **real** backend, which it never
modifies:

```text
tablet --(dev tunnel)--> 127.0.0.1:3010 --> 127.0.0.1:3000 (the backend)
```

Everything passes through untouched until a fault is armed on
`127.0.0.1:3011` (`POST /ctl`). The faults reproduce byte for byte what the
backend itself sends:

| Field | Effect |
|---|---|
| `rejectHandshakes: n` | the next *n* `/devices` CONNECTs get the `DEVICE_AUTH_UNAUTHORIZED` frame and are not forwarded |
| `unavailableHandshakes: n` | the same with the `DEVICE_AUTH_UNAVAILABLE` frame |
| `legacyRejectHandshakes: n` | the same with the bare `{"message":"Unauthorized"}` of a backend older than the codes |
| `serverDisconnect: true` | every open `/devices` socket gets `41/devices,` (namespace DISCONNECT) and is closed |
| `loginReject: bool` | `POST /device-auth/login` gets the exact `401 DEVICE_CREDENTIAL_REJECTED` body without reaching the backend, so nothing in the database changes |
| `cutMs: ms` | drops every relayed connection and refuses new ones |
| `closeDevices: true` | closes every open `/devices` WebSocket gracefully; behind a dev tunnel the tablet notices in seconds instead of after the ping timeout |
| `blockDevicesMs: ms` | `closeDevices`, then every WebSocket upgrade is answered `503` for *ms* while HTTP keeps passing: socket down, REST up |
| `failCurrentMs: ms` | `GET /device/remote-sessions/current` is answered `503` for *ms* without reaching the backend; everything else passes |

Bodies are never logged, and tokens appear only as `tok#n`. Run it with
`NODE_PATH=../remote_control_backend/node_modules node tool/realtime_harness/fault_relay.js`.
The tablet needs a build whose `BACKEND_BASE_URL` points at the forwarded relay
port.
