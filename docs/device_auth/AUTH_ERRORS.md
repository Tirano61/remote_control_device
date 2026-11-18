# Device authentication errors and enrollment retention

How `remote_control_device` reads the answers it gets while authenticating,
and why none of them deletes the stored enrollment.

Contract: [`docs/backend/ENDPOINTS.md`](../backend/ENDPOINTS.md) — *Application
error codes*, `POST /device-auth/login`, `GET /device-auth/check-status` — and
[`docs/backend/REALTIME.md`](../backend/REALTIME.md), *Authentication*.

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
Socket.IO handshake refused ──> renew ───┼── 401 + code ──> report ──> CredentialRefused
                                         └── anything else ──> nothing reported;
                                             the call fails as retryable /
                                             the socket retries on its timer
```

Only a renewal answered `401 DEVICE_CREDENTIAL_REJECTED` reaches
`DeviceCredentialRevocation`. A report supersedes an attempt in flight, so a
late login answer cannot put a refused device back in `Ready`.

### Socket.IO

A `connect_error` counts as the namespace refusing the token only if its
message is exactly `Unauthorized` (REALTIME.md). A proxy page or an error text
containing the word is a transport failure. Even the exact message only starts
a renewal; it never proves anything about the credential. An upgrade refused by
an intermediary (`401`/`302` on the WebSocket request) is a transport failure
too, retried with the socket's own backoff.

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
* **Fresh JWT refused by the socket.** If a Device JWT minted moments ago is
  refused at the handshake again, the realtime channel stops (as before) and
  stays disconnected until the session is re-established; it does not spin
  through logins.
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
