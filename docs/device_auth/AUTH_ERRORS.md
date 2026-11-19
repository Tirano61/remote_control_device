# Device authentication errors and enrollment retention

How `remote_control_device` reads the answers it gets while authenticating,
and why none of them deletes the stored enrollment.

Contract: [`docs/backend/ENDPOINTS.md`](../backend/ENDPOINTS.md) — *Application
error codes*, `POST /device-auth/login`, `GET /device-auth/check-status` — and
[`docs/backend/REALTIME.md`](../backend/REALTIME.md), *Authentication* and
*Handshake errors*.

## Why this exists

Until Prompt 33 the client treated **any** HTTP `401` as "the credential was
revoked" and wiped the `deviceSecret`. A VS Code dev tunnel switched to
*Private* answers `401` (and `302` to a sign-in page) to everything, so a
correctly enrolled tablet behind it lost its credential and asked for a new
enrollment. Prompt 32 reproduced it with isolated servers; those scenarios are
now permanent tests.

## The one confirmed rejection

```text
POST /device-auth/login
HTTP 401
body decoded as a JSON object (JSON content type)
body.code == "DEVICE_CREDENTIAL_REJECTED"   (exact string)
```

That is all. `message`, `error` and `statusCode` are not read — every `401`
says `Unauthorized`. The check lives in
[`device_credential_rejection.dart`](../../lib/features/device/data/network/device_credential_rejection.dart)
and is called only from the login data source, the one route where the code
means anything.

The code is an application signal, not a proof of origin: anything that can
forge the response can forge the body. Over the dev tunnel the TLS certificate
is the tunnel's, so a rejection there is trusted as much as the tunnel is.

## Classification

| Answer | Data layer | Domain failure | Meaning |
|---|---|---|---|
| login `200` with a token | `DeviceSessionModel` | — | authenticated (after check-status) |
| login `401` + `DEVICE_CREDENTIAL_REJECTED` | `DeviceCredentialRejectedApiException` | `CredentialRejectedFailure` | **refused** |
| any other `401` (HTML, empty, no code, other code, text/plain, malformed, other route) | `UnauthorizedApiException` | `AuthFailure` | nothing confirmed |
| `3xx` on any call | `UnexpectedRedirectApiException` | `ServerFailure` (`redirect …`) | an intermediary; not followed |
| `5xx`, other status, `200` that is not the documented JSON | `ServerApiException` | `ServerFailure` | nothing confirmed |
| timeout, no connection, DNS, TLS | `NetworkApiException` | `NetworkFailure` | nothing confirmed |
| secure store unreadable | — | `StorageFailure` | nothing confirmed |

`AuthFailure` on `POST /device-enrollment/activate` keeps its own meaning there
(wrong `publicId` or code); no stored credential is involved.

## Redirects are never followed

`ApiClient` sets `followRedirects: false`, `maxRedirects: 0`. The backend never
redirects, so a `3xx` is a tunnel sign-in page or a captive portal. Following
it used to turn

```text
authenticated GET -> 302 -> tunnel sign-in -> 401
```

into a `401` that looked like the backend's, and sent the request somewhere
that is not the backend. Now the `302` itself is the answer: a `ServerFailure`,
no renewal, no Bearer token sent to the other origin (tested for the same host
and for another origin).

## Session states

[`DeviceSessionBloc`](../../lib/features/device/presentation/bloc/session/device_session_bloc.dart)
is the only owner of the decision.

```text
local credential? ──no──> NotEnrolled
       │yes
       ↓
POST /device-auth/login
       ├── 401 DEVICE_CREDENTIAL_REJECTED ──> CredentialRefused
       ├── anything else that is not 200 ───> AuthenticationUnavailable
       ↓ 200
GET /device-auth/check-status
       ├── 200 ──> Ready
       ├── 401 ──> suspend; log in once more
       │            ├── 200 + check-status 200 ──> Ready
       │            ├── 401 DEVICE_CREDENTIAL_REJECTED ──> CredentialRefused
       │            └── anything else ──> AuthenticationUnavailable
       └── anything else ──> AuthenticationUnavailable
```

| State | Device JWT | Credential | Socket / support / remote session | Retries |
|---|---|---|---|---|
| `Ready` | held | kept | allowed | — |
| `AuthenticationUnavailable` | dropped | kept | released / reset | automatic: 5, 10, 20, 40, then every 60 s; manual "Reintentar" |
| `CredentialRefused` | dropped | **kept** | released / reset | none automatic; manual "Reintentar" |
| `ReEnrolling` | none | kept until the new one is stored | released / reset | — |
| `NotEnrolled` | none | none | released / reset | — |

### Authorisation is suspended, not the enrollment

Every attempt starts by dropping the in-memory Device JWT
(`SuspendDeviceAuthorization`), and every state other than `Ready` holds none.
Without a JWT no authenticated request is sent and the `/devices` socket is
not opened. `withdrawsDeviceAuthorization(state)` is what the support and
remote-session coordinators react to: they reset their blocs, and resetting the
remote session closes the peer connection, the control channel and
MediaProjection downstream. Commands that still arrive on a closed channel run
nothing.

### A check-status 401 buys exactly one renewal

A `401` from check-status means the JWT was not accepted — possibly not even by
the backend. It is never a rejection of the credential (the contract says this
`401` never carries the code). The bloc drops the JWT, logs in once more, and
checks again. A second refusal of a freshly minted JWT is
`AuthenticationUnavailable`: no loop.

### Runtime discoveries

While `Ready`, two things can find out that the credential is refused, both by
renewing the JWT after a `401`:

```text
authenticated REST call ──401──> renew ──┐
DEVICE_AUTH_UNAUTHORIZED ──> renew ──────┤
Socket.IO io server disconnect ──> renew ┼── 401 + code ──> report ──> CredentialRefused
                                         └── anything else ──> nothing reported;
                                             the call fails as retryable /
                                             the socket recovers on its backoff
```

Only a renewal answered `401 DEVICE_CREDENTIAL_REJECTED` reaches
`DeviceCredentialRevocation`. A report supersedes an attempt in flight, so a
late login answer cannot put a refused device back in `Ready`.

It cannot put a Device JWT back in memory either. The token store has an
*epoch*, which every withdrawal bumps (`SuspendDeviceAuthorization` calls
`clear()`). A login reads the epoch before the request leaves and installs its
token only if the epoch is unchanged when the answer arrives. Before Prompt 35,
a login still on the wire when a refusal was confirmed installed its token
afterwards, so `CredentialRefused` could hold a JWT.

### Socket.IO

The `/devices` handshake answers a refusal with a stable `data.code`
([Handshake error codes](#handshake-error-codes-prompt-36)).
`DEVICE_AUTH_UNAUTHORIZED` starts a renewal, `DEVICE_AUTH_UNAVAILABLE` does
not. Neither proves anything about the credential; only the renewal's
`401 DEVICE_CREDENTIAL_REJECTED` does. A proxy page, an error text containing
"unauthorized", or an upgrade refused by an intermediary (`401`/`302` on the
WebSocket request) is a transport failure, retried with the socket's own
backoff.

[Socket.IO recovery](#socketio-recovery) covers the cases the socket cannot
recover from by itself.

## Socket.IO recovery

[`DeviceRealtimeBloc`](../../lib/features/device/presentation/bloc/realtime/device_realtime_bloc.dart)
owns it.

### Root cause fixed in Prompt 35

Prompt 34 reproduced it with the real client against the backend's own gateway.
The tablet could stay offline until the app was restarted:

* **Terminal stop.** After a second handshake refusal with no connection in
  between, the bloc stopped for good (`ConnectionError(retrying: false)`). The
  session stayed `Ready`, so the coordinator never asked for the channel again.
* **Infrastructure errors read as a refusal.** The backend middleware turns
  every failure of its check into `Unauthorized`, including a PostgreSQL error.
  One database blip spanning two handshakes was enough to strand the tablet.
* **`io server disconnect` waited forever.** `socket_io_client` 3.1.6 destroys
  the socket when the server disconnects it, and does not reconnect. The client
  reported it like a lost transport, so the screen showed "Reconectando..."
  forever. A deactivated device never renewed its JWT, so it never learnt that
  it was refused.
* **Uncaught async error.** On that same disconnection the package closes the
  WebSocket without awaiting the close. The close fails with
  `WebSocketConnectionClosed`, and nothing catches it.

### What destroys the socket, and who reconnects

| Signal | Cause | Who reconnects |
|---|---|---|
| `RealtimeDisconnected`, `RealtimeConnectFailed()` | lost transport, network, timeout | the package, same socket, same JWT |
| `RealtimeHandshakeRejected` | `DEVICE_AUTH_UNAUTHORIZED`: expired JWT, deactivated device, revoked credential. Also the bare `Unauthorized` of a backend older than the codes | the bloc, after a renewal |
| `RealtimeHandshakeUnavailable` | `DEVICE_AUTH_UNAVAILABLE`: the backend could not check the token | the bloc, **same JWT, no login** |
| `RealtimeServerDisconnected` | `io server disconnect`: the backend closed the socket (deactivation, re-enrollment elsewhere) | the bloc, after a renewal |
| `RealtimeConnectFailed(transportRetrying: false)` | a namespace refusal this client cannot read: unknown code, malformed body, other message | the bloc, after a renewal |

The client picks between them with `socket.active`, which is the package's own
answer to "will I reconnect?". A close the app asked for never produces a
signal, because listeners are detached first.

When the bloc reconnects, it releases the dead socket (a destroyed socket is
never reused). After `DEVICE_AUTH_UNAVAILABLE` it opens a new socket with the
current JWT once the backoff step has passed (see
[Handshake error codes](#handshake-error-codes-prompt-36)). After anything else
it renews the JWT through `POST /device-auth/login`, and then handles the
answer:

* **`200`:** opens a new socket with the new JWT.
* **`401 DEVICE_CREDENTIAL_REJECTED`:** stops the channel. The session moves to
  `CredentialRefused`:
  * the JWT is dropped and the socket closed;
  * support and the remote session are reset;
  * the credential is **kept**;
  * nothing retries until the user taps **Reintentar**.
* **Anything else:** nothing learnt; the renewal is retried after 15 s.

### Backoff

```text
                                            renewal             DEVICE_AUTH_UNAVAILABLE
first recovery since a stable connection    at once             15 s
then                                        15, 30, 60, 60 s    30, 60, 60 s, ...
```

Both kinds share one count: an UNAVAILABLE followed by an UNAUTHORIZED is the
second step, not a fresh first one.

* **It never stops by itself.** A refused fresh JWT is what a database blip
  looks like from the tablet, and blips heal.
* **The count resets only after a stable connection.** It resets when a
  connection that stayed up at least 30 s is lost. A backend that accepts the
  socket and drops it straight away costs one login per step, not one per drop.
  No timer runs while connected: stability is read from the clock when the
  connection ends.
* **There is one retry at a time.** There is never more than one retry timer.
  Logins are serialised, so a renewal never starts while another one is still
  waiting for its answer, even one from an older generation.
* **One login at a time, application-wide (Prompt 36).** `RenewDeviceToken` is
  shared by REST and Socket.IO. A call made while a login is on the wire joins
  it instead of starting another, so an earlier login can never land after a
  later one and replace its token.
* **Configuration:** `AppConfig.realtimeRecoveryBackoff` and
  `AppConfig.realtimeStableConnectionPeriod`.

### Generations

Every start, stop and close begins a generation. A login answer or a timer from
an older generation does nothing: it installs no socket, adopts no token, emits
nothing and schedules nothing.

The client also numbers its sockets and drops callbacks from a released one. A
late `connect`, `connect_error` or `disconnect` never speaks for the current
socket.

### A reconnection never resumes a remote session by itself

This is unchanged, and `io server disconnect` is now covered too
(`test/app/webrtc_coordinator_test.dart`, group 19):

* Any realtime state other than `Connected` suspends control at once.
* A gesture that arrives while control is suspended is dropped, not queued.
* The reconnection triggers `GET /device/remote-sessions/current`, and only
  that answer can confirm the session again.
* If the answer says the session is gone, the peer and the capture are closed.
  A `CLOSED` session is never recovered.
* The 45 s authority grace period and the backend's 60 s grace are untouched.

### The uncaught close error

Sockets are built, connected and disposed inside `runInSocketZone`
([`socket_zone.dart`](../../lib/features/device/data/realtime/socket_zone.dart)).

* That zone absorbs **only** `WebSocketConnectionClosed`, the error the package
  leaves behind when it closes a WebSocket the server had already closed.
* Every other error goes to the parent zone, so real bugs stay observable.
* Synchronous exceptions still reach the caller.
* No global error handler was added.

### Handshake error codes (Prompt 36)

Prompt 33 BACKEND gave the `/devices` refusals a stable code. Until then the
middleware answered `Unauthorized` both when it refused a token and when its
own database check failed, so every PostgreSQL blip cost the tablet a login
that could only fail against the same database.

#### Contract

```text
44/devices,{"message":"Unauthorized","data":{"code":"DEVICE_AUTH_UNAUTHORIZED"}}
44/devices,{"message":"Service unavailable","data":{"code":"DEVICE_AUTH_UNAVAILABLE"}}
```

`socket_io_client` 3.1.6 hands `onConnectError` the packet data unchanged: a
`Map` with `message` and `data.code`. Both refusals destroy the socket
(`socket.active == false`). Verified on 2026-11-19 against the shared backend on
port 3000 and through the `…-3000` tunnel, with a malformed token that is
refused before any database access, and with the isolated harness.

#### Classification

[`classifyHandshakeError`](../../lib/features/device/data/realtime/device_realtime_payloads.dart):

| `connect_error` | Kind | Signal |
|---|---|---|
| `data.code == "DEVICE_AUTH_UNAUTHORIZED"` | `unauthorized` | `RealtimeHandshakeRejected` |
| `data.code == "DEVICE_AUTH_UNAVAILABLE"` | `unavailable` | `RealtimeHandshakeUnavailable` |
| no `data.code`, message exactly `Unauthorized` (map or string) | `legacyUnauthorized` | `RealtimeHandshakeRejected` |
| unknown code, `code` not a string, `data` not a map, another message, `Service unavailable` without its code | `unrecognized` | `RealtimeConnectFailed(transportRetrying: false)` |
| transport errors (`{msg, desc, type: TransportError}`, `{error: 'server error', code}`, strings, exceptions) | `unrecognized` | `RealtimeConnectFailed()`, the package retries |

* **The code decides, not the message.** With the messages swapped, the code
  still decides. The message is read for one thing only: recognising a backend
  older than the codes by its exact `Unauthorized`.
* **Only `data.code` counts.** The engine's `{error: 'server error', code: …}`
  has a top-level `code`; it is a transport error.
* **An unknown code grants nothing.** It is recovered the way every
  unrecognised namespace refusal already was: release the socket and renew on
  the backoff. A renewal is never less safe than waiting, and a confirmed
  refusal still needs the login's `401 DEVICE_CREDENTIAL_REJECTED`.

#### DEVICE_AUTH_UNAUTHORIZED

Unchanged from Prompt 35:

1. Control is suspended (the state is not `Connected`) and the socket released.
2. The JWT is renewed through the login: at once after a stable connection,
   otherwise on the backoff.
3. A new socket is opened with the new JWT.
4. A login answered `401 DEVICE_CREDENTIAL_REJECTED` stops the channel:
   `CredentialRefused`, enrollment kept, nothing automatic.

Two additions:

* Before logging in, the bloc reads the token store. If it holds a token newer
  than the refused one (REST renewed it while the socket waited), that token is
  presented instead of minting another.
* If the store is empty when the login answers (authorisation was withdrawn
  meanwhile, so the epoch kept the token out), no socket is opened.

#### DEVICE_AUTH_UNAVAILABLE

```text
DEVICE_AUTH_UNAVAILABLE
        ↓
Reconnecting / ConnectionError         (never Connected: control suspended)
        ↓
release the socket; keep the JWT and the enrollment; no login
        ↓
backoff: 15 s, 30 s, 60 s, 60 s, ...   (never at once)
        ↓
new socket with the JWT the store holds now
        ├── accepted ──> Connected ──> REST re-read decides the session
        ├── DEVICE_AUTH_UNAVAILABLE ──> next step
        └── DEVICE_AUTH_UNAUTHORIZED (expired meanwhile) ──> renewal on the backoff
```

* **Keeping a token is not trusting it.** Nothing is `Connected`, and nothing
  is authorised, until a handshake is accepted and the REST reads confirm the
  session. A `CLOSED` session is never recovered.
* **"The JWT the store holds now".** It is read when the retry comes due, not
  when the refusal arrived. If REST renewed it in between, the newer token is
  presented; an older one never replaces it. If the store is empty
  (authorisation withdrawn), nothing is presented and nothing is scheduled: the
  session is about to stop the channel.
* **Expiry during the outage.** The backend checks signature and expiry before
  touching the database, so an expired JWT gets `DEVICE_AUTH_UNAUTHORIZED` even
  while the database is down. That starts a renewal, and the expired token is
  never presented again. While the database is down the login answers `500`,
  which confirms nothing and is retried after 15 s; the enrollment is kept.
* **Generations.** A stop, a restart or a close cancels the pending retry, and
  a timer of an older generation does nothing.
* **Unchanged.** `io server disconnect` still renews. A close the app asks for
  never reconnects. There is never a second socket or a second timer.

### Tools

`tool/realtime_harness/` holds two tools:

* **An isolated backend** built from the backend's own gateway and auth code.
  `test/integration/socket_reconnect_isolated_test.dart` drives it; that test
  is skipped unless `REALTIME_HARNESS` is set.
* **A fault relay** for physical tests. It reproduces the backend's refusals
  (`DEVICE_AUTH_UNAUTHORIZED`, `DEVICE_AUTH_UNAVAILABLE`, the legacy bare
  `Unauthorized`) and disconnections, byte for byte, in front of the real
  backend, without modifying it. `closeDevices` closes the tablet's socket
  gracefully, which a dev tunnel forwards at once.

## Why a confirmed rejection keeps the credential

`DEVICE_CREDENTIAL_REJECTED` is the same answer for:

```text
unknown deviceId
device exists but isActive = false        ← an admin may reactivate it
no unrevoked credential
deviceSecret does not match (including one replaced by a re-enrollment)
```

The tablet cannot tell a temporarily deactivated device from a credential that
is gone for good. If it wiped the credential, a reactivation would be useless —
the device would need a new enrollment code anyway. So:

* authorisation is withdrawn immediately (JWT, socket, support, remote session,
  screen, remote control);
* the credential stays in Android-Keystore-backed secure storage;
* the screen says the authentication was refused and offers **Reintentar** and
  **Activar de nuevo**;
* nothing is retried on its own;
* a retry after a reactivation logs in with the same credential and returns to
  `Ready`; a retry against a really revoked credential stays `CredentialRefused`.

Keeping the credential is not keeping authorisation: only a login and a
check-status accepted by the backend lead to `Ready`.

### Voluntary re-enrollment

"Activar de nuevo" opens the enrollment form with a warning that it replaces
the stored activation and that the current one is kept until the new one
completes, plus **Cancelar** back to the refusal. `EnrollDevice` overwrites the
stored credential only after the backend activated the device and returned the
new `deviceSecret`. A failed or cancelled re-enrollment leaves the old one in
place. Nothing in the application deletes the credential any more.

## Limitations

* **Refusal reasons are not disclosed.** The tablet cannot tell a deactivated
  device from a replaced credential; the user or the technician decides
  between retrying and re-enrolling.
* **A credential that is really revoked stays stored** until a new enrollment
  replaces it. It authorises nothing and is never sent anywhere but
  `POST /device-auth/login`, and only when the user retries.
* **Not a proof of origin.** Something able to produce the exact JSON body over
  the transport can produce a refusal. The consequence is bounded — a withdrawn
  authorisation and a retry button, no data loss.
* **Fresh JWT refused by the socket — fixed in Prompt 35** (see
  [Socket.IO recovery](#socketio-recovery)). Until then: if a Device JWT minted moments ago is
  refused at the handshake again, the realtime channel stops (as before) and
  stays disconnected until the session is re-established; it does not spin
  through logins.
* **Socket.IO handshake codes (Prompt 36).** See
  [Limitations (Prompt 36)](#limitations-prompt-36).
* **Activation `401`.** `POST /device-enrollment/activate` has no application
  code; a tunnel's `401` there reads as "code not valid". No stored credential
  is affected.

## Seen on a device

Physical T10A (`LSTT10M2026081504`, publicId `645-589-107`), 2026-11-18, debug
build of this branch. Faults were injected by a local relay behind a second
dev-tunnel port (`…-3010`, Public), forwarding to the shared backend; the `…-3000`
tunnel, the backend and its database were not touched. The rejection in D was
synthesised by the relay with the exact contract body, so no login reached the
database. "Store" is a hash of the encrypted secure-storage file (ciphertext
only, never decrypted), identical in every step.

| Test | Relay | Tablet | Backend (web console) |
|---|---|---|---|
| A normal | pass | login 200, check-status 200, socket up, "Conectado" | Online |
| B ambiguous | `401` HTML (Private-tunnel page), then empty `401`, `302` to another origin, `503` | "Autenticación no disponible", automatic retries 5 s apart, no enrollment screen, `302` not followed | Offline |
| C recovery | pass | recovered by itself on the next backoff step (~34 s), no tap | Online |
| D refusal | login `401 DEVICE_CREDENTIAL_REJECTED` | "Autenticación rechazada"; one login, then nothing for 85 s; no socket, no REST call; "Activar de nuevo" shows the replace warning and "Cancelar" returns; an explicit retry still refused | — |
| E reactivation | pass, then "Reintentar" | login 200 with the same stored credential, check-status 200, socket up | Online |

Not exercised on the device: a refusal discovered at runtime during a live
remote session (covered by `test/app/webrtc_coordinator_test.dart`, group 19).

### Socket.IO recovery on the T10A (Prompt 35)

Setup, 2026-11-19 (times UTC):

* **Tablet:** physical T10A (`LSTT10M2026081504`), debug build of
  `fix/device-socket-reconnection`, installed with `install -r` (same
  `firstInstallTime`, enrollment kept).
* **Backend:** the shared one, untouched (`dist` built from
  `feature/backend-device-auth-error-contract`).
* **Fault injection:** `tool/realtime_harness/fault_relay.js` behind a second
  dev-tunnel port (`…-3010`, Public).
  * Handshake refusals and the namespace `DISCONNECT` are the backend's exact
    frames.
  * The login refusal is the exact contract body and is synthesised by the
    relay, so no login reached the database.
* **Observation:** the relay log (`tok#n` labels only), the web console's
  device list, and screencaps. No mobile-mcp and no UiAutomation.

| Test | Fault | Tablet / relay | Console |
|---|---|---|---|
| A start | none | login `tok#1`, check-status 200, socket accepted, REST re-read | Online |
| B Wi-Fi | `svc wifi disable` for 25 s | "Reconectando..."; on Wi-Fi back, the package reconnected with the same `tok#1`, no login, REST re-read | Online |
| C refusals | 3 handshakes refused | `tok#1` refused → login at once → `tok#2` refused → **15 s** → `tok#3` refused → **30 s** (11:43:55.9 → 11:44:28.4) → `tok#4` accepted, REST re-read; no restart | Offline → Online |
| D server disconnect | `41/devices,` after a connection up for 23 s | not stable, so the **60 s** step applied: login 62.7 s later, `tok#5` accepted | Online |
| D' server disconnect | `41/devices,` after a connection up for 40 s | login after 2.6 s, `tok#7` accepted 4 s after the disconnect | Online |
| E refusal | `41/devices,` + login 401 `DEVICE_CREDENTIAL_REJECTED` | "Autenticación rechazada"; then **no request at all for 127 s** (no login, no REST, no socket) | Offline |
| F retry | relay passes again, "Reintentar" tapped | login 200 with the same stored credential (`tok#6`), check-status 200, socket accepted, REST re-read; no re-enrollment | Online |

The app process stayed the same from the first scenario to the last. Afterwards
the `…-3000` build was reinstalled.

Only covered by tests, not on the device:

* the PostgreSQL error in the handshake (the integration harness, E1/E2);
* a server disconnect during a live remote session (`webrtc_coordinator_test`,
  group 19). It needs Accessibility and a MediaProjection consent by hand, and
  `enabled_accessibility_services` was `null` on the T10A throughout.

### Handshake error codes on the T10A (Prompt 36)

Setup, 2026-11-19 (times UTC):

* **Tablet:** physical T10A (`LSTT10M2026081504`), debug build of
  `fix/device-socket-handshake-error-codes` for `…-3010`, installed with
  `install -r` (same `firstInstallTime`, enrollment kept).
* **Backend:** the shared one on port 3000, untouched (`nest start --watch`
  serving `dist` built from backend `main` f7eba5a). Its codes were checked
  first with a malformed token, which is refused before any database access.
* **Fault injection:** `tool/realtime_harness/fault_relay.js` behind the
  `…-3010` dev-tunnel port (Public), injecting the backend's exact
  `CONNECT_ERROR` frames. The login refusal in E is synthesised by the relay, so
  it never reached the database.
* **Web console:** `remote_control_web` served locally on `:5173` against the
  same backend.
* **Observation:** the relay log (`tok#n` labels only; a relay restart resets
  them), screencaps, the console, and a filtered logcat. No mobile-mcp and no
  UiAutomation.

| Test | Fault | Tablet / relay | Console |
|---|---|---|---|
| A normal | none | login `tok#2`, check-status 200, socket accepted, REST re-read; "Conectado" | Online |
| B unavailable | 2 × `DEVICE_AUTH_UNAVAILABLE` | refused 13:07:19.98 and 13:07:35.69 (**+15.7 s**), **always `tok#2`, no login**; "Reconectando...", assistance disabled | Offline |
| C recovery | relay passes | accepted 13:08:08.25 (**+32.6 s**: the 30 s step), same `tok#2`, still no login, REST re-read | Online |
| D expired | UNAVAILABLE, then `DEVICE_AUTH_UNAUTHORIZED` armed during the backoff | UNAVAILABLE 13:08:56.70 (`tok#2`) → +16.0 s same `tok#2` refused UNAUTHORIZED → login on the 15 s step (13:09:29.9) → `tok#3` accepted; one login | Online |
| D′ legacy | bare `{"message":"Unauthorized"}` | renewed at once (login 2.5 s later) → `tok#4` accepted | Online |
| E refusal | UNAUTHORIZED + login `401 DEVICE_CREDENTIAL_REJECTED` | login at once, then "Autenticación rechazada"; **no request at all for 132 s**; "Reintentar" → login 200 with the same stored credential (`tok#5`), check-status 200, socket accepted | Offline → Online |
| F active session | `DEVICE_AUTH_UNAVAILABLE` during an `ACTIVE` assistance (`closeDevices`) | baseline remote tap ran (10:18:03.675 local); after the drop the tablet showed "Control remoto: suspendido hasta confirmar con el servidor" and a tap sent then **did not run** (console: "La asistencia no está activa en el dispositivo"); same JWT accepted 17.7 s later, no login, `GET /device/remote-sessions/current`, then a new tap ran (10:18:45.674) | Online, "Toque enviado" |
| F′ closed meanwhile | UNAVAILABLE, then "Finalizar asistencia" in the console during the backoff | same JWT accepted after the 30 s step (the previous connection had lasted 23 s, not stable), REST read: no session; "La asistencia fue cerrada por el servidor", capture indicator gone, `dumpsys media_projection` empty; nothing recovered | Online, history +1 |

The app process stayed the same from A to F′. The user accepted the technician
and granted MediaProjection by hand; Accessibility was already enabled. A
cut behind the dev tunnel only reaches the tablet after the Engine.IO ping
timeout (~45 s), which outlasts the backend's 60 s session grace once the 15 s
step is added, so F used the relay's `closeDevices` (a graceful WebSocket
close, which the tunnel forwards: the tablet re-handshook 3.2 s later).
Afterwards a `…-3000` build of this branch was reinstalled; it connected
through the `…-3000` tunnel, Online in the console, with Accessibility still
enabled.

In F′ the console also closed its peer connection, so the screen capture may
have been taken down by that before the REST read; either way the read found no
session and nothing came back.

Only covered by tests, not on the device:

* REST renewing the JWT during the backoff (`device_realtime_bloc_test`, P36
  13), and a withdrawal during the backoff or during the login;
* an unknown or malformed code (`device_realtime_contract_test`);
* a real PostgreSQL failure and a JWT that really expires while the database is
  down (the isolated harness: E1–E5, with the backend's own gateway).

### Limitations (Prompt 36)

* **A database that hangs without failing** still produces no `connect_error`
  (backend limitation): the client sees a transport close after the server's
  `connectTimeout` and the package retries with the same token.
* **The client does not read the JWT's expiry.** It relies on the backend
  checking expiry before the database, so an expired token is answered
  `DEVICE_AUTH_UNAUTHORIZED`. A backend that answered UNAVAILABLE for an
  expired token would keep the client on the same token, bounded by the 60 s
  step, until the database answered.
* **An unknown future code is renewed.** That costs one login per backoff step
  until the client learns the code.
* **Not a proof of origin.** As with the REST codes, anything able to forge the
  frames can forge `data.code`. The worst a forged UNAVAILABLE can do is delay
  the next attempt by one step; it never authorises anything.
