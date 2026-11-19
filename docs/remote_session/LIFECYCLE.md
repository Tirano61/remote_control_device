# Remote session lifecycle on the device

How `remote_control_device` holds a `RemoteSession`, and above all how it lets go
of one. The backend contract is in
[docs/backend/ENDPOINTS.md](../backend/ENDPOINTS.md) (`GET
/device/remote-sessions/current`, `POST /device/remote-sessions/:id/close`) and
[docs/backend/REALTIME.md](../backend/REALTIME.md) (`remote-session:*`).

## The rule

```text
REST is the state. Realtime only says "look again".
```

with one exception, which only points one way:

```text
Anything that withdraws the technician's access may act before REST answers.
Nothing that grants it may.
```

Three things withdraw it: FINALIZAR on the tablet, `remote-session:closed` for
the session held, and the tablet losing the means to confirm the session (see
[Authority](#authority)).

## States

`RemoteSessionBloc` emits one of these:

| State | Meaning | Control | Peer / screen |
| --- | --- | --- | --- |
| `RemoteSessionInitial` / `Loading` | not asked yet / first read in flight | no | no |
| `RemoteSessionIdle` | the backend says there is no live session (`lastClosure`: who closed the previous one from the other side) | no | no |
| `RemoteSessionConnecting` | backend `CONNECTING` | no (`session_not_active`) | may negotiate |
| `RemoteSessionActive`, `confirmed` | backend `ACTIVE`, confirmed after the socket last came up | yes, on the current channel | yes |
| `RemoteSessionActive`, `suspended` | backend `ACTIVE` last time, not confirmable now | **no** | kept, at most for the grace period |
| `RemoteSessionEndedLocally` | ended here: FINALIZAR (`userRequest`) or grace expired (`authorityLost`) | **no** | **torn down** |
| `RemoteSessionClosedRemotely` | `remote-session:closed` named the session held | **no** | **torn down** |
| `RemoteSessionUnavailable` | the first read failed: unknown, not "none" | no | no |

`RemoteSessionLive` (`Connecting` or `Active`, either authority) is the only
family the coordinators read as "an assistance exists". Only `Active` +
`confirmed` is read as "a command may run". `RemoteSessionEndedLocally` and
`RemoteSessionClosedRemotely` are deliberately outside the live family.

## Four things that are not the same

```text
local authorisation revoked   The user pressed FINALIZAR. From that instant this
                              tablet obeys no command for the session, has let
                              go of any remote touch, has closed the data
                              channel and the peer connection, and has stopped
                              MediaProjection. Nothing the backend or the
                              network does afterwards undoes it.
                              State: RemoteSessionEndedLocally.

close confirmed by backend    POST /close answered 200 with the CLOSED session,
                              or a later GET /current no longer returns that
                              session as live. Only now does the device say the
                              session is closed. State: RemoteSessionIdle.

close pending reconciliation  The POST did not get a confirming answer (network,
                              timeout, 5xx, 401, 400, or 409 with the session
                              still live). The backend may still hold the
                              session ACTIVE. The tablet still refuses it, and
                              says so: "La asistencia terminó en esta tablet,
                              pero no se pudo confirmar el cierre con el
                              servidor." State: RemoteSessionEndedLocally with
                              lastFailure.

new session, new consent      A different remoteSessionId. It can only exist
                              after the ended one stopped being live (one live
                              session per device) and after the user accepted
                              a new request with PERMITIR. It goes through the
                              normal path, including a new MediaProjection
                              dialog.
```

The device never claims the backend closed a session it did not confirm.

## FINALIZAR ASISTENCIA

```text
press
  │  synchronous, before any await
  ├─ session id added to the in-memory "ended here" set
  ├─ state ──> RemoteSessionEndedLocally(confirming: true)
  │
  │  delivered to the coordinators on the next microtask, in this order
  ├─ WebRtcActiveRemoteSessionChanged(null)
  │     control no longer authorised; queued commands dropped without
  │     running; a remote touch abandoned (abandonTouch, never a release, so a
  │     drag is not dropped where it happened to be)
  ├─ WebRtcRemoteSessionChanged(null)
  │     1. control withdrawn again, before any await (idempotent)
  │     2. data channel and peer connection closed, generation bumped
  │     3. MediaProjection stopped, including a capture still being started
  ├─ SignalingSessionEnded: the signaling room is left
  │
  ├─ ended-session marker written to secure storage
  └─ POST /device/remote-sessions/:id/close
        200 CLOSED      marker cleared, Idle, then GET /current
        404 / 409       GET /current decides; the session stays ended either way
        anything else   stays RemoteSessionEndedLocally(lastFailure)
```

The local teardown does not wait for the POST and nothing in it depends on the
POST's result. The POST is sent while the teardown runs (the marker write is the
only thing awaited before it), so on the wire the close normally leaves after
control has been withdrawn and the peer close and capture stop have started; the
network round trip cannot complete before them.

A second press finds no live state and does nothing. While the confirmation is
pending the panel offers `REINTENTAR`, which sends the close again and nothing
else.

## Monotonic

A session in the ended set is never mapped to a live state again:

The same table holds for a session ended because its grace period ran out, and,
except for the close being re-sent, for one closed by the backend.

| What arrives later | Result |
| --- | --- |
| `GET /current` returns it `ACTIVE` or `CONNECTING` | stays ended; the close is sent once more |
| `remote-session:active` for it | ignored, no read |
| `remote-session:created` for it, a reconnection | read; stays ended |
| an offer for it | dropped: the room was left and no live session matches |
| a data channel from the old peer | closed: its generation is gone |
| MediaProjection granted after the end | stopped on arrival, never attached |
| a GET answer that was already in flight | mapped through the ended set: stays ended |
| a reset (credential revoked, re-enrolment) | `Initial`; the set and the marker are kept |

## The marker

`EndedRemoteSessionStore` (implemented by `SecureEndedRemoteSessionStore`, key
`remote_session.ended_pending`) keeps the one `remoteSessionId` ended here and not
yet confirmed. It is read once per application run before the first `/current`
answer is mapped, so an application killed after a failed close does not resume
the session on its next start.

- It holds an operational identifier, not a credential. It grants nothing and the
  backend checks ownership on every call made with it.
- It is written before the POST and cleared only on a backend confirmation (200
  `CLOSED`, or a successful `/current` that no longer returns it as live).
- Since Prompt 38 it also records whether a close is owed
  (`remote_session.ended_pending_cause`): absent for FINALIZAR, `authorityLost`
  for a session the tablet stopped by itself. The latter is still refused after a
  restart, but no close is ever sent for it. A marker of an older build has no
  cause and reads as FINALIZAR, which is what it was.
- It survives clearing the device credentials, so a re-enrolled installation still
  refuses it.
- A store that cannot be read or written is logged and does not block the local
  end. What is lost in that case is only the guarantee across a restart.

## Reconciliation

There is no timer and no retry loop. A pending close is sent again, at most once
per cue, when a `/current` read that reached the backend still returns the ended
session live. The cues are the existing ones:

```text
socket (re)connected        including the first connection after a start
remote-session:created / closed
support request reached ACCEPTED
REINTENTAR on the ended panel
```

A tablet that cannot reach the server stays ended and waits. If only HTTP is
failing while the socket stays up, nothing re-sends the close until one of those
cues happens or the user presses REINTENTAR.

With the current backend contract the device cannot make the backend close a
session it cannot reach. While the confirmation is pending the backend keeps the
session `ACTIVE` and its request `ACCEPTED`: the technician remains blocked from
starting another session and the tablet from making a new request, until the
close lands, the technician presses FINALIZAR on their side, or the backend's own
automatic close (`SYSTEM`, backend Prompt 31, not merged at the time of writing)
ends it. This client does not rely on that close; it only reacts to it.

## The technician's FINALIZAR, and the backend's SYSTEM close

`remote-session:closed` naming the session held is acted on before the read:

```text
remote-session:closed { remoteSessionId, endedBy }   endedBy TECHNICIAN, SYSTEM,
  │                                                  or anything else: same path
  │  synchronous, before any await
  ├─ the id is recorded as closed by the backend (in memory; CLOSED is terminal)
  ├─ state ──> RemoteSessionClosedRemotely(endedBy)
  │
  ├─ WebRtcActiveRemoteSessionChanged(null)   control withdrawn, touch abandoned
  ├─ WebRtcRemoteSessionChanged(null)         channel + peer closed, capture stopped
  ├─ SignalingSessionEnded                    room left
  │
  └─ GET /current
        null             ──> Idle(lastClosure: endedBy)
        same session live ──> still ClosedRemotely (a read that was overtaken)
        another session   ──> adopted the normal way (a new request and PERMITIR)
        failure           ──> still ClosedRemotely(lastFailure)
```

A closure naming another session withdraws nothing held; it is recorded, so a
read that later returns that id live is still refused, and a read follows as for
any cue. The id in the payload is never adopted: it only matches.

## Authority

The tablet hears that a session was closed only over the `/devices` socket. With
the socket down, a session the backend may already have closed is still `ACTIVE`
on the tablet, while WebRTC, which does not go through the backend, keeps
working. That was C2. The tablet now treats the socket as what its authority
hangs on.

Policy since Prompt 38 (see [Authority recovery](#authority-recovery-prompt-38)
for why it changed):

```text
socket up, and a GET /current that STARTED after it came up says ACTIVE
                                    ──> confirmed: commands run; the signaling
                                        room is joined only now
socket drops                        ──> suspended at once (synchronous):
                                        commands refused with session_not_active,
                                        queued ones dropped, a touch abandoned.
                                        Peer, channel and screen kept.
                                        Grace period starts (75 s).
                                        GET /current re-read with backoff
                                        2, 4, 8, 8... s, socket up or down
socket back                         ──> still suspended, NOT rejoined; GET sent;
                                        backoff starts over at 2 s
  GET says ACTIVE, socket up,
    read started after it came up   ──> confirmed again; grace and re-reads
                                        cancelled; room joined. Commands sent
                                        while suspended were refused, not
                                        queued: none of them runs.
  GET says ACTIVE, socket down      ──> stays suspended (never confirms)
  GET says null / another session   ──> the session is over: everything torn
                                        down at once, socket up or down
                                        (Idle(interrupted: true))
  GET fails, times out, 401, 5xx    ──> stays suspended; next re-read scheduled;
                                        grace keeps running
remote-session:closed               ──> ClosedRemotely at once, as always
FINALIZAR while suspended           ──> the user's end: EndedLocally(userRequest),
                                        POST close (endedBy DEVICE, correct)
credential revoked                  ──> reset: Initial, everything torn down
grace runs out while suspended      ──> ended here, torn down exactly as
                                        FINALIZAR: EndedLocally(authorityLost),
                                        marker written (closeOwed: false).
                                        NO close is sent, then or later: the
                                        device is not in the room, so the
                                        backend closes it itself (SYSTEM)
```

Read epochs. Every change of the socket's state, every closure of the session
held, and every reset moves a counter. A read remembers the counter it started
with and can only confirm if it is unchanged and the socket is up when it
answers. So:

* a GET in flight when the socket drops, or when it comes back, confirms nothing;
* a GET that started while the socket was down confirms nothing after it is back;
* a GET that answers `ACTIVE` after `remote-session:closed` for that session maps
  to closed, whatever its epoch.

A failure never upgrades: a confirmed session stays confirmed through a failed
read only while the socket stays up (the channel that would carry a close is
still there); a suspended one stays suspended.

### Why 75 s, and when it starts

`RemoteSessionBloc.defaultAuthorityGracePeriod` = 75 s =
`backendDisconnectGrace` (60 s) + 15 s, counted from the moment **this tablet**
sees its socket leave `connected`. The backend's own grace
(`REMOTE_SESSION_DISCONNECT_GRACE_MS`, 60 s) starts when **the backend** notices
the device has no joined socket. The two clocks are never compared; no backend
timestamp is read.

* control does not depend on the window at all: it is suspended from the
  tablet's first instant of doubt. The window only bounds how long the screen may
  keep flowing to a peer the tablet cannot vouch for;
* it is a backstop. While the backend can be reached it decides: the re-reads
  see its `SYSTEM` close (60 s after it noticed) at most one backoff step (8 s)
  plus a round trip later;
* not shorter than 60 s: a tablet that noticed the loss together with the
  backend must not give up on a session the backend would still let it rejoin;
* the 15 s over it cover a backend noticing a clean close slightly later than
  the tablet, one backoff step and the read that sees the close — so with the
  backend reachable it is the backend's close, not this timer, that ends it;
* it is not restarted by a socket that flaps, by a reconnection whose read
  fails, or by a read answering ACTIVE while the socket is down.

Worst case for the screen after a backend close the tablet cannot hear and cannot
read (backend unreachable): the tablet's own detection delay (up to ~45 s for a
half-open connection) plus 75 s, against 45 s before. A technician console that
received `remote-session:closed` closes its peer anyway, which stops the capture
20 s later (orphan window); seen in C2 below. For control: only the detection
delay, as before.

### Peer connection FAILED or CLOSED

Not a backend matter, but the same principle: when the peer that carried the
screen fails, is closed by the other end, or is abandoned mid-negotiation,
control of it is gone with it (generation bumped, queue dropped, touch
abandoned), and the capture is stopped after 20 s
(`WebRtcSessionBloc.defaultOrphanCaptureTimeout`) unless a new offer for the
same live session attaches it. The device never renegotiates by itself.

The web may also give up on its connection before this side notices, and
offer from a new one while the tablet's peer still reads CONNECTED. That offer
replaces the peer only with the session's authority **confirmed**; suspended,
it is refused and the old peer kept. See
[PEER_RECOVERY.md](../webrtc/PEER_RECOVERY.md).

### MediaProjection stopped by Android

See [SCREEN_SHARING.md](../webrtc/SCREEN_SHARING.md#when-the-user-stops-the-share-from-android).
Control in that session is withdrawn for good and its peer closed; the session
itself stays for FINALIZAR or the technician.

### What the user sees

| Situation | Headline | Control line |
| --- | --- | --- |
| ACTIVE, confirmed | Asistencia en curso | Control remoto: habilitado |
| CONNECTING | Conectando con el técnico... | Control remoto: disponible cuando la asistencia esté activa |
| socket down | Reconectando... | Control remoto: suspendido hasta confirmar con el servidor |
| socket back, not reconciled | Verificando la asistencia... | Control remoto: suspendido hasta confirmar con el servidor |
| grace expired | Asistencia interrumpida + "Se perdió la conexión con el servidor y la asistencia se detuvo por seguridad." + "Podrás solicitar una nueva asistencia cuando el servidor registre el cierre." No REINTENTAR | (no panel line: torn down) |
| afterwards, or a re-read made while suspended found it gone | the request panel with "La asistencia anterior terminó durante una pérdida de conexión con el servidor." | (torn down) |
| closed by the backend | Asistencia finalizada + who closed it | (torn down) |
| ended here | Asistencia finalizada / Finalizando la asistencia... | (torn down) |
| screen stopped by Android | unchanged headline, "Pantalla: Android detuvo la captura" | Control remoto: deshabilitado en esta asistencia |

The accessibility service being enabled is never enough for "habilitado".

### Residual risks

* **Detection delay.** Until the tablet's socket leaves `connected`, the tablet
  cannot know. A half-open TCP connection is detected only by the Socket.IO ping
  timeout (up to ~45 s). Control keeps running in that interval if the backend
  closed the session without the event reaching the tablet. Closing it needs
  something the backend does not offer today (a heartbeat or an expiry the tablet
  can check), or a shorter ping configuration on both sides.
* **Socket up, HTTP down.** A confirmed session stays confirmed while the socket
  is up, even if `/current` fails: the socket is what would carry a close. If the
  backend could close a session without emitting the event on a live socket, the
  tablet would not notice until the next reconnection.
* **Grace expiry no longer sends a close (Prompt 38).** It relies on the
  backend's automatic `SYSTEM` close, merged in the backend, so the device's
  behaviour now does depend on it: against a backend without the lifecycle the
  session would stay `ACTIVE` there until the technician closes it. See
  [Authority recovery](#authority-recovery-prompt-38) for the backend changes
  that would remove the dependency.

## Seen on a device

Validated on 2026-11-17 on the T10A (`LSTT10M2026081504`, Android 16), debug
build of this branch, against the shared backend through a VS Code dev tunnel and
the web console on `localhost:5173`. Times are the tablet's logcat. FINALIZAR was
pressed on the tablet itself, never through mobile-mcp or UiAutomation.

```text
normal close (12:11:28)      data channel reset +0 ms, peer CLOSED +4 ms, capture
                             stopped +61 ms and released +79 ms. No tap reached the
                             tablet afterwards; no media projection, no foreground
                             service, no notification. Backend closed the session.

close without HTTP          port forwarding stopped (tunnel answers 404). Peer
(13:51:09)                  CLOSED, capture stopped +68 ms and released +86 ms.
                             Panel: "La asistencia terminó en esta tablet, pero no
                             se pudo confirmar el cierre con el servidor." with
                             REINTENTAR; REINTENTAR while unreachable failed again
                             and resumed nothing. Credentials kept.

reconnection                 forwarding restored: socket reconnected, the pending
                             close reached the backend (its history recorded it,
                             with nobody pressing FINALIZAR on the web) and the
                             tablet went to Idle. No new peer, no capture.

FINALIZAR during a DRAG      touch 1 started 14:04:40.852, held 41.358, moving.
(14:04:51)                   FINALIZAR at 51.282; touch 1 cancelled
                             reason=abandoned at 51.416 (+134 ms), no release
                             logged. Peer CLOSED 51.442, capture stopped 51.484
                             and released 51.495. InputDispatcher afterwards:
                             "no displays touched". Backend closed the session.
```

What the DRAG run does and does not show:

- FINALIZAR was pressed with a key event (`KEYCODE_ENTER` on the focused button),
  not `input tap`. An injected touch makes Android cancel an accessibility gesture
  by itself, which would have ended the drag regardless of this code.
- The drag ran over this application's own window, which must be in front for
  FINALIZAR to be pressed, so there was no drop target. "No drop" rests on the log
  (the touch ended `abandoned`, never `released`) and on no pointer remaining
  down, not on an item that visibly failed to drop.
- The abandon went through the stroke-mismatch cancel described in
  `docs/webrtc/CONTROL_CHANNEL.md`. The pointer was gone afterwards, but the
  `ACTION_CANCEL` itself was not observed, so that note stays provisional.
- The data channel has no log line of its own on the T10A in this run; its
  closing is implied by the peer connection reaching `CLOSED`.

Seen during the validation, outside this change: a `401` from something other
than the backend (a dev tunnel switched to private) is taken by the existing
device authentication as a revoked credential, the credentials are cleared and
the tablet asks for re-enrollment. FINALIZAR stayed irreversible through it and
the pending close was confirmed after re-enrolling, because the marker survives
clearing the credentials.

## Authority loss: seen on a device

Validated on 2026-11-18 on the T10A (`LSTT10M2026081504`, Android 16), debug build
of `fix/device-session-authority-loss` (`d154d2c`), against the backend of
`feature/backend-remote-session-lifecycle` (Prompt 31, `dist` built 07:30 the same
day, default lifecycle settings: grace 60 s). Tablet and web console
(`localhost:5173`) both reached the backend through the same VS Code dev tunnel;
the cuts were made by stopping port forwarding of port 3000 in VS Code, so both
sockets dropped while WebRTC stayed up over Wi-Fi. Consent (PERMITIR,
MediaProjection, *Stop sharing*) was given by hand on the tablet; no mobile-mcp or
UiAutomation. Times are the tablet's clock (about 0.9 s ahead of the PC); Dart
logs read from the VM service, native ones from logcat, PostgreSQL read-only.

```text
cut, back after the grace (session 806f974a)
  08:01:31.5  forwarding stopped
  08:01:36.1  swipe still executed: Android had not noticed yet
  08:01:40.4  socket down detected (+8.9 s): authority suspended
  08:01:48.2  swipe rejected (session_not_active)
  08:02:25.4  45.0 s after detection: ended here (authorityLost); peer closed,
              capture stopped and released within 0.2 s; POST close 404 (tunnel)
  08:02:40.4  backend: CLOSED, endedBy SYSTEM, request COMPLETED  (backend clock)
  08:03:27.9  socket back; GET /current null: "no longer live: confirmed".
              No peer, no capture, no pointer left down.

cut, back within the grace (session 7a4fa33a)
  08:07:18.6  forwarding stopped
  08:07:27.4  detected (+8.7 s): suspended. 5 commands rejected while down
  08:08:09.1  socket back and rejoined; a swipe at 08:08:09.5 still REJECTED:
              the GET had not answered
  08:08:10.2  GET /current ACTIVE: confirmed (2.2 s before the grace ran out)
  08:08:11.9  commands run again. None sent while suspended ran later.
              Same peer, same capture, no renegotiation; backend kept ACTIVE.

technician gone, SYSTEM close with the tablet connected (same session)
  08:09:38    console tab closed
  08:09:52.4  peer FAILED; capture without receiver
  08:10:12.5  capture stopped exactly 20 s later (orphan window)
  08:10:37.9  backend: CLOSED, endedBy SYSTEM (60 s after the technician left)
  08:10:39.4  remote-session:closed (system) received: control withdrawn,
              room left, GET null. Panel: "El servidor cerró la asistencia
              porque se perdió la conexión."

Android "Stop sharing" (session 2f16a677)
  08:19:20.285  system stops the projection
  08:19:20.296  ScreenCapturer onStop; released 08:19:20.326
  08:19:20.327  reported to Dart; control withdrawn 08:19:20.342;
                peer closed 08:19:20.448
  08:21:44.0    the console resumed the session and sent a new offer:
                "offer ignored: Android stopped the screen capture"; no peer,
                no dialog. Panel: "Pantalla: Android detuvo la captura",
                "Control remoto: deshabilitado en esta asistencia".
  08:22:11.9    technician FINALIZAR: remote-session:closed (technician)
                received with the tablet connected; CLOSED TECHNICIAN.

FINALIZAR on the tablet (session 5e2c52c4)
  08:25:32.46   ended here; peer closed +3 ms; capture stopped +74 ms and
                released +112 ms; a tap sent afterwards reached nothing;
                POST close 200, CLOSED DEVICE.
```

After every revocation: `dumpsys media_projection` null, no
`MediaProjectionForegroundService`, `InputDispatcher` "no displays touched",
credentials kept.

What these runs do not show:

* the variant in which the backend closes **inside** the tablet's grace and a
  reconnection discovers it over REST: with both sides detecting the cut at the
  same time (~9 s) the tablet's 45 s always ran out before the backend's 60 s.
  It is covered by `test/app/session_authority_loss_test.dart` only;
* a DRAG held while control was withdrawn: only the absence of a pointer
  afterwards was checked on the device. The abandon path was seen on a device in
  Prompt 29.

Seen during the runs, outside this change:

* detection takes about 9 s after the tunnel stops forwarding; one command ran
  in that window (the backend still held the session ACTIVE then);
* when forwarding was restored the tunnel answered as Private (302) for about
  3 s; the tablet only retried its socket then, so no 401 reached the
  credential logic;
* the backend stores `createdAt` in UTC and `connectedAt` / `endedAt` in local
  time (-03:00) in `timestamp without time zone` columns. If the CONNECTING TTL
  reads `createdAt` as local time it would fire about 3 h late. Not verified;
  it is the backend's to check;
* "remote ICE candidate ignored: it names another session" is also printed when
  there is no negotiation at all: the reason is right, the wording is not.

## Authority recovery (Prompt 38)

M1 of the Prompt 37 audit: the tablet ended assistances by itself, recorded as
`endedBy: DEVICE`, while the backend would still have let it recover them.

### Root cause

Three things together, all in `RemoteSessionBloc` (Prompt 30 design):

1. **No re-read while suspended.** A suspended session was re-read only on the
   existing cues (socket up, realtime events). One failed `GET /current` after a
   reconnection left it suspended — socket up, room rejoined, REST working again
   a second later — until the grace ran out.
2. **45 s < 60 s.** The local grace was shorter than the backend's
   `REMOTE_SESSION_DISCONNECT_GRACE_MS`, on purpose (stop sharing before the
   backend could close). With both ends noticing a clean close at the same time,
   the window 45–60 s was one in which the backend would accept a rejoin and the
   tablet had already given up.
3. **The expiry sent `POST /device/remote-sessions/:id/close`.** The backend
   records that call as `endedBy: DEVICE`, the user's FINALIZAR. Worse, in case 1
   the device had rejoined the room, so the backend would never have closed the
   session itself: the tablet's close was the only thing ending it.

### The instants, and what each clock counts from

```text
1 socket disconnected        tablet: "realtime disconnected" (graceful close: same
                             instant at the backend; silent cut: up to ~45 s later
                             on either side, by ping timeout)
2 authority suspended        same synchronous handler as 1     -- local 75 s starts
3 first REST failure         a re-read 2 s after 2, or the read on reconnection
4 local timer                = 2 (never restarted)
5 socket recovered           socket_io_client backoff (2 s doubling to 20 s, +-50 %):
                             can lag the end of the outage by up to ~20 s
6 REST success               the first re-read that answers
7 ACTIVE confirmed           6 with the socket up and the read started after 5;
                             the room is joined only now    -- backend grace stops
8 local automatic end        2 + 75 s, if 7 never happened
9 backend SYSTEM close       backend notices the device's last joined socket gone
                             + 60 s                          -- backend grace
```

The backend's 60 s run from its own observation of 1 (or of the device leaving
the room); the tablet's 75 s from 2. Neither clock reads the other.

### Policy

| Requirement | How |
| --- | --- |
| no command during a loss | suspended synchronously on 1; only `Active` + `confirmed` obeys |
| gestures abandoned | the touch is abandoned (never released) on suspension |
| control only after REST ACTIVE | confirmation = socket up + a read started after it + ACTIVE |
| CLOSED never reactivated | ended / closed ids are kept; reads mapped through them |
| FINALIZAR irreversible | unchanged; also while suspended |
| a prolonged loss ends safely | 75 s backstop, everything torn down |
| nothing suspended forever | the 75 s timer is never restarted |
| SYSTEM close not prevented | the device joins the room only when confirmed, so a tablet that cannot confirm is absent to the backend and its grace runs |
| explicit revocation ends at once | `remote-session:closed`, `/current` answering null or another session (now also with the socket down), revoked credential (reset) |

Retries: 2, 4, 8, 8… s after each answer, one read at a time, restarted at 2 s
whenever the socket changes. A read answering ACTIVE with the socket down keeps
the session suspended; it never confirms.

### Attribution

```text
FINALIZAR on the tablet                   POST close                      -> DEVICE
tablet stopped it (75 s, authority lost)  nothing sent                    -> SYSTEM
backend: a side away > grace              automatic                       -> SYSTEM
technician FINALIZAR                      POST /remote-sessions/:id/close -> TECHNICIAN
Android stopped MediaProjection           session kept for FINALIZAR / technician
irreversible WebRTC failure               session kept; capture stops after 20 s
```

The tablet never sends a close the user did not ask for. The cost: the
technician and the support request stay `ACTIVE`/`ACCEPTED` until the backend's
`SYSTEM` close — at most 60 s after the device left, since a suspended tablet is
not in the room.

### Backend changes this would benefit from (separate prompt)

Not required by this fix; the contract was not changed.

* An optional reason on `POST /device/remote-sessions/:id/close`, e.g.
  `{ "reason": "AUTHORITY_LOST" }`, stored as a separate `endReason` with
  `endedBy` left as it is, would let the tablet release the session at once on
  an automatic end without it reading as FINALIZAR.
* Exposing the grace (or the instant the backend will close) in
  `GET /device/remote-sessions/current` would let the tablet align its backstop
  with the backend's real deadline instead of assuming the default 60 s. If
  `REMOTE_SESSION_DISCONNECT_GRACE_MS` is changed, `backendDisconnectGrace` here
  must follow by hand.
* Separate: `createdAt` UTC vs `connectedAt`/`endedAt` local time (seen in
  Prompt 31) is still the backend's to check; the device reads none of them for
  timing.

### Seen on a device

2026-11-19, T10A (`LSTT10M2026081504`, Android 16), debug builds against the
shared backend (PID 12688, untouched) through the Public dev tunnel port 3010 →
`tool/realtime_harness/fault_relay.js` → 127.0.0.1:3000. Web console
(`remote_control_web` main `bf0fee0`, release build served on `localhost:5173`)
straight to 3000, so only the tablet was faulted. Faults: `blockDevicesMs`
(tablet's `/devices` closed gracefully and refused, REST up), `failCurrentMs`
(only `GET /device/remote-sessions/current` answers 503), `cutMs` (everything).
PERMITIR and the MediaProjection dialog were accepted by hand by the user;
SOLICITAR and FINALIZAR on the tablet with `input tap` on the app's own buttons;
no mobile-mcp, no UiAutomation, no `am force-stop`. Dart logs from the VM
service (device clock, ~0.1 s from the PC); `endedBy` read through
`GET /remote-sessions/:id` with the console's technician session.

```text
M1 on main (16c74b8), session 74108de5
  15:17:03.559  suspended (block 10 s + failCurrent 60 s)
  15:17:22.046  socket back; room rejoined 23.464 (backend grace stopped)
  15:17:22.500  GET /current 503 — and no other read
  15:17:48.564  45.0 s: ended on the tablet; POST close 200
  backend       CLOSED, endedBy DEVICE, 15:17:51.166 — nobody pressed FINALIZAR

A  brief loss (fix), session ea675abb, block 15 s
  15:21:16.471  suspended; re-reads at +2, +7, +16, +26 s: ACTIVE, not confirmed
  15:21:50.456  socket back (client backoff: 34 s for a 15 s outage)
  15:21:52.809  GET ACTIVE -> confirmed; join 52.811 (after the read)
  15:22:19      remote tap completed; no close sent

B  past the old limit (fix), same session, block 10 s + failCurrent 50 s
  15:22:27.994  suspended
  15:22:39.782  socket back — NOT rejoined; GET 503
  15:22:41.857  technician tap rejected: session not active
  15:22:46-23:19 six re-reads, 503
  15:23:21.816  GET ACTIVE -> confirmed (+53.8 s); join +54.1 s (< 60 s)
  15:23:34      remote tap completed; backend ACTIVE; no close sent

D  FINALIZAR during the recovery, same session, block 60 s
  15:24:10.381  FINALIZAR tapped while "Reconectando..."
  15:24:10.582  ended here; capture stopped 10.747; POST close 200
  backend       CLOSED, endedBy DEVICE (the user's, correctly)
  15:25:01      socket back: /current empty, no join, no projection

F  new assistance after a definitive close: sessions 918dbaf9, 43b9ad62,
   49063fa9 each started with PERMITIR, a new MediaProjection and ACTIVE

E  technician closes while the tablet cannot hear it, session 918dbaf9
  15:26:26.667  suspended (block 60 s)
  15:26:36.975  technician FINALIZAR: CLOSED, endedBy TECHNICIAN
  15:26:43.930  re-read null, socket still down: torn down (+7.0 s);
                capture stopped 44.065. Nothing sent.

C1 prolonged loss, backend reachable, session 43b9ad62, block 120 s
  15:30:45.057  suspended; 8 re-reads, all ACTIVE (never confirmed)
  15:31:45.659  backend CLOSED, endedBy SYSTEM (+60.6 s)
  15:31:48.426  re-read null: torn down (+2.8 s after the backend)

C2 prolonged loss, backend unreachable, session 49063fa9, close + cut 110 s
  15:36:29.876  suspended
  15:37:31.618  backend CLOSED, endedBy SYSTEM
  15:37:38.474  peer disconnected (the console closed its side)
  15:37:44.882  75.0 s: ended on the tablet, no close sent; capture
                stopped 45.002. Panel "Asistencia interrumpida", no REINTENTAR
  15:38:29.975  back: /current empty, marker cleared, idle with
                "La asistencia anterior terminó durante una pérdida de conexión
                con el servidor."
```

Across the fixed build the relay saw no `POST …/close` except D's. After every
end: `dumpsys media_projection` null, no foreground service,
`TouchStatesByDisplay: <no displays touched>`, accessibility still enabled and
bound, credentials kept.

Found on the device and fixed in this branch: the idle note first read "terminó
**por** una pérdida de conexión"; in E the technician had closed it, so it now
says "durante".

What these runs do not show:

* a silent half-open cut (detection by ping timeout): every run used a graceful
  close so both ends noticed at once;
* a DRAG held during the drop on the device; covered by
  `test/app/session_authority_loss_test.dart` only;
* a credential revoked during a recovery, a restart with an `authorityLost`
  marker, a late read after the grace and skewed backend timestamps: unit and
  coordinator tests only.

### Residual risks

* **Client reconnection lag.** socket_io_client's own backoff (up to 20 s, ±50 %)
  can leave the socket down well after the network is back (A: 34 s for a 15 s
  outage), eating into the backend's 60 s. Not changed here.
* **Backend detects later than the tablet by more than 15 s** (a half-open
  connection seen only by the backend's ping timeout): the tablet may give up
  while the backend would still accept a rejoin. It then sends nothing, so the
  backend still records `SYSTEM`.
* **Screen exposure while unreachable** grew from 45 s to 75 s after detection.
* **Default grace assumed.** A backend configured with a longer grace makes the
  tablet give up first; with a shorter one the backend simply closes first.
