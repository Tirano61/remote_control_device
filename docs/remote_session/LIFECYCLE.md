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

close confirmed by backend    POST /close answered 200 with that same session
                              CLOSED and endedAt set — whoever closed it first:
                              the close is idempotent, so endedBy may be DEVICE,
                              TECHNICIAN or SYSTEM — or a later GET /current no
                              longer returns that session as live. Only now does
                              the device say the session is closed. State:
                              RemoteSessionIdle.

close pending reconciliation  The POST did not get a confirming answer (network,
                              timeout, 5xx, 401, 400, a 200 that does not name
                              that session CLOSED with endedAt, or 404/409 with
                              the session still live). The backend may still hold the
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
        200, same id, CLOSED, endedAt (any endedBy)
                        marker cleared, Idle, then GET /current
        200 otherwise   not a confirmation: GET /current decides (ServerFailure)
        404 / 409       GET /current decides; the session stays ended either way
        anything else   stays RemoteSessionEndedLocally(lastFailure)
```

See [Idempotent close](#idempotent-close-prompt-39) for every answer.

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
- It is written before the POST and cleared only on a backend confirmation (a 200
  naming that session `CLOSED` with `endedAt`, or a successful `/current` that no
  longer returns it as live). A 200 about another id never clears it.
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
                                        queued ones dropped, a touch abandoned,
                                        screen frames held back (Prompt 40).
                                        Peer, channel and capture kept.
                                        Grace period starts (75 s).
                                        GET /current re-read with backoff
                                        2, 4, 8, 8... s, socket up or down
socket back                         ──> still suspended, NOT rejoined; GET sent;
                                        backoff starts over at 2 s
  GET says ACTIVE, socket up,
    read started after it came up   ──> confirmed again; grace and re-reads
                                        cancelled; room joined; screen frames
                                        let through again. Commands sent
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

Read order (Prompt 41). Epochs say whether a read *may* confirm; they do not say
whether its answer is newer than one already applied. Reads are also numbered
when they leave, and an answer overtaken by a newer one never takes a
confirmation away and never grants anything; an answer without the session
still ends it when it proves the session over. See
[Stale answers (Prompt 41)](#stale-answers-and-the-screen-after-a-micro-cut-prompt-41).

### Why 75 s, and when it starts

`RemoteSessionBloc.defaultAuthorityGracePeriod` = 75 s =
`backendDisconnectGrace` (60 s) + 15 s, counted from the moment **this tablet**
sees its socket leave `connected`. The backend's own grace
(`REMOTE_SESSION_DISCONNECT_GRACE_MS`, 60 s) starts when **the backend** notices
the device has no joined socket. The two clocks are never compared; no backend
timestamp is read.

* control does not depend on the window at all: it is suspended from the
  tablet's first instant of doubt, and since Prompt 40 so is the screen. The
  window only bounds how long the capture and the peer are kept for a recovery
  (see [Video during an authority loss](#video-during-an-authority-loss-prompt-40));
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
read (backend unreachable): since Prompt 40, the tablet's own detection delay
only (up to ~45 s for a half-open connection); from then on no frame leaves the
tablet, and the capture itself stops at 75 s. A technician console that
received `remote-session:closed` closes its peer anyway, which stops the capture
once the orphan window runs out (20 s until Prompt 41; since then 45 s, and only
while the tablet is in the session's room); seen in C2 below. For control: only
the detection delay, as before.

### Peer connection FAILED or CLOSED

Not a backend matter, but the same principle: when the peer that carried the
screen fails, is closed by the other end, or is abandoned mid-negotiation,
control of it is gone with it (generation bumped, queue dropped, touch
abandoned), and the capture is stopped after
`WebRtcSessionBloc.defaultOrphanCaptureTimeout` unless a new offer for the
same live session attaches it. Since Prompt 41 that window is 45 s and runs
only while the tablet is joined to the session's signaling room, starting again
in full on every rejoin; see "Stale answers and the screen after a micro-cut (Prompt 41)" below.
The device never renegotiates by itself.

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
| socket back, not reconciled | Verificando la asistencia... + "Pantalla: en pausa hasta confirmar con el servidor" | Control remoto: suspendido hasta confirmar con el servidor |
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
  can check), or a shorter ping configuration on both sides. Since BACKEND
  Prompt 36 the transport notices ~20 s after the last `PING`, and since
  Prompt 42 the tablet suspends 13 s after it: see
  [Heartbeat watchdog](#heartbeat-watchdog-prompt-42).
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
irreversible WebRTC failure               session kept; capture stops after 45 s
                                          in the room (20 s before Prompt 41)
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
  Closed by Prompt 40: frames are held back from detection; only the capture
  is kept for 75 s.
* **Default grace assumed.** A backend configured with a longer grace makes the
  tablet give up first; with a shorter one the backend simply closes first.

## Idempotent close (Prompt 39)

Since `remote_control_backend` `f5b8a1c` (backend Prompt 34) both close endpoints
are idempotent. Verified in the backend code, not only in the copied docs:
`closeByDevice` and `closeByTechnician` go through `closeOwned`, which locks the
row with the owner in the `WHERE` (`SELECT … FOR UPDATE`, `deviceId` from the
Device JWT), runs the one transition (`closeWithin`) only if the row is still
live, and re-reads the committed row inside the same transaction. `closedNow` is
true only for the request that made the transition, and only that one emits
`remote-session:closed`. `closeBySystem` takes the same lock.

### What the tablet makes of each answer

```text
POST /device/remote-sessions/:id/close
  200, same id, CLOSED, endedAt     confirmed — whoever closed it first.
                                    endedBy DEVICE, TECHNICIAN, SYSTEM or
                                    unknown: all the same to the tablet
                                    (RemoteSession.confirmsCloseOf)
  200, another id                   not a confirmation. The marker of the session
  200, CONNECTING / ACTIVE          ended here stays, nothing in the body is
  200, unknown status               adopted, one GET /current decides (lastFailure
  200, CLOSED without endedAt       ServerFailure), no second close for that cue
  404                               no session of this device has that id:
                                    GET /current decides
  409                               the session is still live and its request
                                    cannot complete; nothing was written:
                                    GET /current decides (normally: still live,
                                    so it stays ended here, marker kept)
  timeout, network, 5xx, 401, 400   nothing known: stays ended, marker kept
```

Whatever the answer, the session never becomes live again on the tablet: the
end is decided before the POST is sent, and every path above maps the ended
session through the ended set.

`endedBy` is never required to be `DEVICE`. The close response is the
confirmation for a session the technician or the backend closed first, for
example when their `remote-session:closed` was lost or arrived while the POST
was in flight. The tablet does not show who closed it in that case: the user
pressed FINALIZAR, and that is what the idle screen reflects.

`endedAt` and `endedBy` are now part of `RemoteSession` (lenient parsing like
`connectedAt`). They are read only for the confirmation check and the log line;
no screen depends on them.

### Retries and the marker

Unchanged from Prompt 37/38, and now safe in every case because a repeat is
always a `200` for a session already closed:

* the marker is written before the POST and cleared only by a confirming `200`
  or by a successful `/current` that no longer returns that session live;
* a pending close is sent again at most once per cue (socket back, application
  start, realtime event, REINTENTAR) when `/current` still returns the session
  live. A non-confirming `200` does not add a retry of its own;
* a marker with `closeOwed: false` (`authorityLost`, Prompt 38) never produces a
  POST, so a backend `SYSTEM` close is never turned into a `DEVICE` one;
* a different session clears an old marker (a device has one live session at a
  time) and is never addressed by the old close.

### Compatibility

* With a backend older than `f5b8a1c` a repeat answered `409`. The tablet maps
  `404`/`409` to "re-read `/current`", which confirmed the end the moment the
  session was no longer live, so old backends keep working.
* The only behaviour change against the current backend is for answers it does
  not produce: a `200` about another id or without `endedAt` used to be taken
  as a confirmation (another id even cleared the marker of the ended session and
  could put a live session from the close body on screen, suspended).

### Seen on a device

2026-11-20, T10A (`LSTT10M2026081504`, Android 16), debug build of this branch
(`eac7464` + tests) installed as an update, backend `main` `f5b8a1c` (shared,
PID 43164, `dist` built 09:35:01, untouched), reached through the Public dev
tunnel port 3010 → `tool/realtime_harness/fault_relay.js` → 127.0.0.1:3000. Web
console `remote_control_web` `main` `57e36aa`, release build served on
`localhost:5173`, straight to 3000. PERMITIR and every MediaProjection dialog
were answered by hand by the user; SOLICITAR, FINALIZAR and REINTENTAR on the
tablet with `input tap`; no mobile-mcp, no UiAutomation, no `am force-stop`.
Repeated device closes were sent by the relay as the tablet (`deviceClose`,
with the tablet's own Device JWT, never printed); technician-side state read
with `GET /remote-sessions/:id` from the console's origin. Times UTC; the
tablet clock runs ~0.9 s ahead of the PC.

```text
A  FINALIZAR, session 893f4f23
  14:00:46.917  ended on the tablet; signaling left .921, peer closed .922,
                capture stopped 47.072
  14:00:47.080  POST close (after the teardown, not before)
  14:00:50.645  200 CLOSED endedBy DEVICE endedAt 14:00:48.300 -> confirmed

B  repeat, same session, Device JWT, twice
                200 CLOSED DEVICE 14:00:48.300 both times; tablet received
                nothing; technician GET says the same

C  lost response, session 3b4dc2d9 (relay loseCloseResponses 1)
  14:20:31.040  POST close; backend CLOSED DEVICE 14:20:32.034, answer dropped
  14:20:46.384  receiveTimeout -> "no se pudo confirmar el cierre", REINTENTAR
  14:21:06.548  REINTENTAR: POST close
  14:21:09.460  200 CLOSED DEVICE endedAt 14:20:32.034 (the original) ->
                confirmed, marker cleared

F  old closes during a new session, acc49686 ACTIVE
                deviceClose 893f4f23 and 3b4dc2d9: 200 with their own original
                closes; /current still acc49686 ACTIVE (device and technician);
                tablet logged nothing; a remote tap afterwards completed

D  technician closes while the device's POST is in flight, session acc49686
  14:25:22.793  relay holds the device close 9 s
  14:25:23.632  FINALIZAR: ended, capture stopped 23.735, POST 23.742
  14:25:23.128  (PC clock) technician POST close (console origin) -> CLOSED TECHNICIAN
                endedAt 14:25:24.959
  14:25:27.259  remote-session:closed reaches the tablet: already ended, nothing
                more to do
  14:25:34.491  the held POST answers 200 endedBy TECHNICIAN 14:25:24.959 ->
                confirmed. Repeat: same.

E  SYSTEM, three times
  745c6df7, 0afab5b6  the MediaProjection dialog was not accepted within the
                backend's CONNECTING timeout: remote-session:closed SYSTEM,
                everything withdrawn, a capture granted afterwards abandoned
                ("stopped while starting"). Repeats: 200 SYSTEM with the
                original endedAt (14:28:47.991, 14:32:52.674)
  a255d8d5 (controlled) ACTIVE; relay blockDevicesMs + failCurrentMs 150 s
  14:34:44.288  suspended; re-reads 503
  14:35:43.602  backend CLOSED SYSTEM (60.6 s after the socket went)
  14:35:47.513  FINALIZAR on the suspended tablet (it could not know)
  14:35:49.399  its POST: 200 endedBy SYSTEM 14:35:43.602 -> confirmed, although
                the follow-up /current still failed (503)
  14:36:33      socket back: /current null, idle
```

After every end: `dumpsys media_projection` null, `TouchStatesByDisplay: <no
displays touched>`, accessibility enabled and bound, credentials kept, one
Device JWT for the whole run. The relay saw a device-initiated close only after
FINALIZAR or REINTENTAR (A, C ×2, D, E controlled); none for the sessions the
backend closed by itself.

Not shown on a device: a `200` that does not confirm (another id, still live,
no `endedAt`) — the backend does not produce one, so it is covered by
`test/features/remote_session/presentation/remote_session_idempotent_close_test.dart`
and `test/app/irreversible_session_end_test.dart` only; a restart with a close
pending; a 409 (needs an inconsistent support request); a DRAG during
FINALIZAR (unit/app tests, and Prompt 37 on the device).

### Residual risks

* **Idle text after a SYSTEM close.** "El servidor cerró la asistencia porque se
  perdió la conexión" is also shown when the backend closed a `CONNECTING`
  session because the MediaProjection dialog was not answered in time (E). The
  backend gives no reason; the proposed `endReason` (Prompt 38) would fix it.
* **A held/lost close blocks re-reads for up to the receive timeout (15 s).**
  While a close is in flight no sync is started, so a new session is noticed at
  most that much later. Control is never affected.
* **A non-confirming `200` keeps the session ended until a cue.** By design:
  one read, then the normal cues. With a backend that kept answering it, the
  marker would never clear and the backend would keep the session live until
  its own close.

## Video during an authority loss (Prompt 40)

B3 of the Prompt 37 audit: with the session's authority suspended, control
stopped at once but the screen kept reaching the technician for the whole
recovery window.

### Root cause

Since Prompt 30 the suspension reached `WebRtcSessionBloc` only as the
**active** and **confirmed** ids going `null`. The first gates commands, the
second gates a recovery offer. Nothing gated the video track: the peer, the
sender and the capture were deliberately kept for the recovery, so the encoder
went on sending whatever the screen showed. The design said so ("the window only
bounds how long the screen may keep flowing to a peer the tablet cannot vouch
for"). B3 is that sentence measured.

Reproduced on `main` (`b318237`), session `27a4e2e4`, socket blocked 30 s in the
relay with REST up and WebRTC untouched, quick settings opened and closed with
adb every 2 s:

```text
15:00:21.72  authority suspended (tablet log, PC clock); commands refused
15:00:23-47  web: +226 frames decoded, 3.0 MB, 2-23 fps while the screen changed
15:00:48-01:12 web: +50 frames, 100 KB (screen mostly still)
15:01:12.86  socket back + REST ACTIVE: confirmed again
             -> 278 new frames reached the technician during the suspension
```

### Capturing is not transmitting

```text
capture     MediaProjection -> virtual display -> SurfaceTexture -> onFrame
transmit    onFrame -> [gate] -> VideoSource -> encoder -> RTP sender -> peer
control     DataChannel -> RemoteSessionActive + confirmed -> Android
```

The fix puts a gate between the two first lines, on the Android side, before the
encoder: `ScreenCaptureTransmission`, checked first in `ScreenCapturer.onFrame`.
Closed, MediaProjection keeps running and the user's consent and notification
stay, but no frame reaches libwebrtc: no encoder input, no RTP video.

### Policy

| Situation | Capture | Transmission | Commands |
| --- | --- | --- | --- |
| live session, authority confirmed (`CONNECTING` or `ACTIVE`) | running | **open** | `ACTIVE` only |
| socket down | kept | **closed at once** (same handler that suspends) | refused |
| REST failing | kept | closed | refused |
| socket back, REST pending | kept | closed | refused |
| REST confirms the same session | kept, no new dialog | **reopened**, current frame resent | obeyed again |
| REST `null` / another session / `CLOSED` | stopped | closed | gone |
| FINALIZAR (also while suspended) | stopped | closed first | gone |
| `remote-session:closed` (TECHNICIAN or SYSTEM) | stopped | closed first | gone |
| 75 s grace expired | stopped | closed (was already) | gone |
| Android stopped the projection | released by Android | closed | withdrawn for the session |
| a new session | a new capture, new dialog | starts **closed**; opened when confirmed | per its own state |

`CONNECTING` with confirmed authority transmits, as before: the technician sees
the screen before activating. Unconfirmed, nothing does.

### Mechanism

* **Native gate** (`ScreenCaptureTransmission`, `ScreenCapturer.setTransmitting`).
  Starts **closed** for every capture. Switched on the `SurfaceTextureHelper`'s
  thread and waited for, so once the call returns no frame after it passes; a
  frame already past the gate belongs to the authorised period. Counts frames
  admitted and withheld and logs them on each switch, never per frame.
* **Channel**: `setScreenCaptureTransmission {trackId, transmitting}`, applied
  only to the running capture with that id (`RunningScreenCapture.ifRunning`); a
  late call for a replaced capture reaches nothing.
* **Client** (`ScreenCaptureClient.setTransmitting`): one platform call per
  change, in the order made; a refusal stops the capture (last resort) and
  answers `false`, which the bloc records as a failed screen.
* **Decision** (`WebRtcSessionBloc._syncScreenTransmission`): open exactly when
  the capture's session is live, confirmed and not revoked by Android. Called
  synchronously from the authority, live-session and capture handlers; it reads
  the current fields only, so no late callback (a read, an answer, an old peer's
  state) can reopen it. Only the coordinator sets "confirmed".
* **Resume**: opening asks the helper to deliver the current texture again
  (`ScreenCaptureSettleFrame.redeliverNow`). A still screen produces no next
  frame, and the technician would otherwise keep the image from before the
  suspension.

### Alternatives considered

| Option | Why not |
| --- | --- |
| `track.enabled = false` | libwebrtc's `VideoBroadcaster` turns each frame of a disabled track into a black frame of the same size: frames keep flowing and show when the screen changes |
| `sender.replaceTrack(null)` | per sender: every new or replaced peer (recovery) needs the same treatment, and a stale generation could put the track back; it also needs the Dart adapter to hold senders |
| `RTCRtpEncodingParameters.active = false` | per sender too, same generation problem |
| stopping MediaProjection | Android 14+ needs a new consent dialog to capture again: no recovery without asking the user |
| **gate at the source (chosen)** | one switch per capture, whatever peer or sender the track is on; no frame, not even black; consent kept; testable on the JVM and in Dart |

### Consent and Android

* The suspension never stops the projection, so a confirmed recovery resumes
  without a dialog, on the same track.
* A projection Android stopped (`onStop`) is not restarted: that session's
  control stays withdrawn and a later confirmation reopens nothing.
* A new session never inherits a capture: the old one is stopped when its
  session stops being live, and the new one asks Android and starts closed.

### UI

Back online but not confirmed ("Verificando la asistencia..."), the screen line
says *Pantalla: en pausa hasta confirmar con el servidor* instead of
"compartiendo". While "Reconectando..." there is still no screen line (Prompt 30
decision); the control line already says suspended.

### Tests

* JVM: `ScreenCaptureTransmissionTest` (12: starts closed, counts, idempotent
  switches, stop is final, the whole frame path with the settle frame: nothing
  sent while suspended, resume sends the newest image as a real frame or repeats
  the last one once, no redelivery before any frame); `RunningScreenCaptureTest`
  (+2: a change reaches only the capture it names).
* Dart: `test/app/video_authority_suspension_test.dart` (22, every bloc and
  coordinator real): the prompt's 20 cases plus a late read, a loss during the
  consent dialog, a platform refusal and the bloc closing.
  `media_projection_screen_capture_client_test.dart` (+7),
  `flutter_webrtc_screen_media_test.dart` (+3), panel (+1).

### Seen on a device

2026-11-20, T10A (`LSTT10M2026081504`, Android 16), debug build of
`fix/device-video-authority-suspension` against the shared backend (PID 43164,
untouched) through the Public dev tunnel port 3010 →
`tool/realtime_harness/fault_relay.js` → 127.0.0.1:3000. Web console
(`remote_control_web` main `57e36aa`, release build on `localhost:5173`) straight
to 3000, with `RTCPeerConnection` wrapped from Claude in Chrome to sample
`inbound-rtp` once a second (frames received and decoded, bytes, packets, RTX).
Screen changes during each suspension: quick settings expanded and collapsed by
`cmd statusbar` every 2 s. Tablet clock +1.23 s from the PC; times below are PC
time. PERMITIR and the MediaProjection dialog by the user; SOLICITAR and
FINALIZAR with `input tap` on the app's own buttons; no mobile-mcp, no
UiAutomation, no `am force-stop`.

```text
A  normal, session 7bc32341
   15:15:49.77  capture started, gate opened 4 ms later (authority confirmed)
   10 s of changes: +103 frames, 1.37 MB; remote tap-1 completed

B  socket blocked 40 s, REST up
   15:16:54.46  suspended; gate closed 3 ms later (native: admitted 249)
   51 s: web +0 frames, +0 decoded (52 packets, one burst of 8.6 KB, no
        frame assembled); tap rejected session_not_active;
        projection 1, foreground service up
C  15:17:45.28  socket back; 15:17:46.41 REST ACTIVE -> gate reopened
        (native: withheld while suspended 758); no dialog, same peer
   next 8 s: +80 frames, 1.16 MB; tap-3 completed

D  socket 10 s + GET /current 503 for 35 s
   15:18:53.61  suspended; 7 reads answered 503 by the relay
   41 s: web +0 frames (9.2 KB RTX payload padding: retransmitted packets)
   15:19:37.01  REST ACTIVE -> reopened (withheld 744)

F  FINALIZAR during a 90 s block
   15:20:16.36  suspended; 15:20:31.68 FINALIZAR tapped
   14 s: web +0 frames, +0 bytes; peer closed; capture stopped;
   close 200, endedBy DEVICE; socket back 15:21:51.86: /current empty,
   no join, projection 0, foreground service gone

G  new assistance d46b7d7a: PERMITIR and the MediaProjection dialog again,
   a new capture, gate opened once confirmed

E  SYSTEM close: socket blocked, REST up
   16:02:08.23  suspended
   59 s: web +0 frames, +0 bytes, +0 packets
   16:03:08.952 backend CLOSED, endedBy SYSTEM
   16:03:11.81  tablet re-read null: peer closed, capture stopped,
                projection 0 (2.9 s after the backend)
```

After every end: `dumpsys media_projection` with no projection, only the
accessibility service running, `TouchStatesByDisplay: <no displays touched>`,
accessibility still enabled and bound, credentials kept.

The packets seen during B and D are RTX. Measured in D (the RTX counters were
added to the sampler after B): every packet was counted by
`retransmittedPacketsReceived`, all with `retransmittedBytesReceived` 0
(padding) except one burst of 9 225 bytes that `retransmittedBytesReceived`
accounts for byte for byte: libwebrtc's bandwidth probing resends packets
already sent. B shows the same shape (padding plus one 8 649-byte burst).
`framesReceived` and `framesDecoded` did not move in either, so no image, new
or old, was assembled.

What these runs do not show:

* a silent half-open cut, detected only by the ping timeout: every run closed
  the socket gracefully;
* the projection stopped by Android while suspended, a recovery offer while
  suspended, a DRAG during the drop: unit and coordinator tests only;
* the exact last frame before the gate closed: frames already in the encoder
  when it closes still go out. B: none counted after the suspension instant;
  D: one frame in the one-second sample that contains it, not attributable
  either way.

### Residual risks

* **Detection delay.** The gate closes when the tablet notices; until then (up
  to ~45 s for a half-open connection) frames flow, as control did before
  Prompt 30. Unchanged by this fix.
* **In-flight frames.** A frame already past the gate when it closes is
  encoded and sent: at most the frames of the last few tens of milliseconds
  before the suspension, all captured while authorised.
* **RTX padding and probing** keep sending already-sent packets while the gate
  is closed. They carry nothing the technician had not received; it is
  libwebrtc's bandwidth estimation and not configurable from here.
* **The web keeps the last image** received before the suspension on screen.
  That is not new content; the console has no indicator for "paused" (a WEB
  change, separate prompt, if wanted).
* **Resume quality.** The first frame after a long suspension is a delta on the
  encoder's old reference. The web asked for keyframes as needed (`pliCount`
  +2 across D) and decoding resumed at once (D: 14 frames decoded in the
  second after resuming); the image itself was not inspected.

## Stale answers and the screen after a micro-cut (Prompt 41)

D1 of the BACKEND Prompt 35 audit, reproduced there as S2 on the T10A: a 5 s
Wi-Fi cut during an `ACTIVE` session ended with Android asking for the screen
again. Two defects were behind it; only the first was known when the prompt
was written.

### D1: an overtaken `/current` answer took the confirmation away

`RemoteSessionBloc` handles events concurrently, so `/current` reads overlap:
the re-read of a suspended session (Prompt 38) can still be on the wire when the
socket's return causes another. Before this prompt `_adopt` applied every answer
as it arrived, with `_authorityFor(epoch)` of the epoch the read *started* in.
The order that broke S2:

```text
socket drops            suspended; room left; video held
re-read #n leaves       (Wi-Fi still coming back; the request lingers)
socket back             epoch moves; read #n+1 leaves
#n+1 answers ACTIVE     confirmed; room joined again
#n answers ACTIVE       _authorityFor(old epoch) = suspended   <- D1
                        -> SignalingSessionEnded: the room is left again
web's recovery offer    reaches a device that is not in the room: dropped
web                     waits for its 30 s answer deadline
capture                 20 s without a receiver: stopped -> new consent
```

The same happens with two reads of the same epoch answering in reverse order
(an older `CONNECTING` taking `ACTIVE` back and, with it, command authority),
and, worse, an older `ACTIVE` arriving after a newer "no session" brought a
session the backend had closed back to life.

### Freshness policy

Every read is numbered when it leaves (`_readSequence`). For each session a
read returned live, the tablet remembers the number reached when that answer
arrived (`_knownSince`): every read numbered above it left after the backend
already had the session. An answer is weighed by what it proves, not by when
it arrives:

```text
the session held, live                  consistent: nothing changes. Authority is
                                        taken away only by the socket dropping and
                                        by a closure, never by a read about the
                                        same session. The newest read may refresh
                                        it, never move ACTIVE back to CONNECTING
without the session held, from a read
  numbered above _knownSince            proof it is over (CLOSED is terminal):
                                        torn down at once, even if overtaken, and
                                        recorded in _goneAtBackend
  numbered at or below it               may predate the session: proves nothing.
                                        The session is suspended (never confirmed
                                        on that answer) and a fresh read decides
a session in _goneAtBackend,
  _closedRemotely or ended here, live   ignored or mapped to over: never live again
overtaken (an answer newer than it
  was already applied) and it would
  grant something                       not applied; one fresh read, which grants
                                        it if it holds
the newest answer, anything else        applied as before (epoch rule unchanged)
a failure overtaken by an answer        ignored
```

Granting is done only by the newest answer, and confirmation still needs the
read to have started after the socket last came up, with the socket up now.
Withdrawing is done by any answer that proves it. The fresh read made after an
ambiguous answer leaves after the session is known, so its own answer is never
ambiguous about it: this cannot loop.

`CLOSED` and `null` are never discarded just for being late: if the read left
after the session was known, the session is over whatever the order. A
confirmed close of this device (`200 CLOSED` for that id) is the same proof:
a read still on the wire that answers the session `ACTIVE` no longer flips the
state from Idle back to ended-here, and no second close follows from it.
FINALIZAR, `remote-session:closed` and the 75 s grace are unchanged and still
win over any answer. A "no session" that may predate the session does not
clear the FINALIZAR marker either: only a proving answer or the close confirms.

### The screen: the orphan window only runs while an offer can arrive

With D1 fixed, scenario B (below) still asked for MediaProjection again, for a
reason independent of D1. The tablet's peer failed while it was out of the
signaling room; the web's first recovery offer went out at the same moment and
was lost (the device was not joined); the web only offers again when its own
30 s answer deadline and the next step of its schedule (`[0, 5, 15, 30] s`) have
passed, 32 s after the tablet was back in the room. The 20 s orphan window,
counted from the failure, had already stopped the capture.

`WebRtcSessionBloc.defaultOrphanCaptureTimeout` is now **45 s** and runs **only
while the tablet is joined to the room of the capture's session**, the only time
an offer can reach it. Leaving the room cancels it; rejoining starts it again
in full. Out of the room the capture is held, with the transmission gate closed
while the authority is suspended and no peer to transmit to, and that time is
bounded elsewhere: the 75 s authority grace ends the session (and the capture),
and the backend's 60 s grace closes it as `SYSTEM`. 45 s = the web's 30 s answer
deadline + its 5 s step + a REST read and the relay of the offer, with margin.

The 60 s and 75 s deadlines are unchanged. A new session never reuses a capture:
the capture client hands back a running capture only for the same session id,
and `WebRtcRemoteSessionChanged` stops it when its session is gone.

### Tests

* `test/features/remote_session/presentation/remote_session_stale_read_test.dart`
  (24): every read is held by the fake (`holdReads`) and answered in the order
  the test chooses, no clock. S2, normal and reverse order, new confirmation /
  old suspension, new suspension / old confirmation, old socket against new,
  same epoch (CONNECTING after ACTIVE, and an older read that knows more), REST
  ACTIVE after FINALIZAR and after `remote-session:closed`, `null`, `CLOSED`,
  503, timeout, consecutive cuts, retries of old generations, a later session,
  the grace with only stale answers, and the revocations that must not be
  ignored: an overtaken proving `null`, no resurrection, ambiguous `null`
  settled both ways, a confirmed close, a FINALIZAR marker kept by an ambiguous
  `null`. 11 of them fail on the previous bloc.
* `test/app/authority_rest_race_test.dart` (12), every bloc and coordinator
  real: the room stays joined after the late answer, the web's offer is
  accepted, the same capture goes on the new peer without a dialog, video and
  commands come back; B as seen on the T10A (first offer lost out of the room,
  second 32 s after the rejoin); the window still ends a capture nobody takes;
  out of the room for good ends at the grace; a replaced peer reports nothing;
  consecutive cuts; an overtaken proof, a later offer, SYSTEM and FINALIZAR
  during the recovery; a new assistance asks again. S2, the replaced peer,
  consecutive cuts and FINALIZAR fail on the previous bloc; B fails on the
  previous window.
* `test/features/webrtc/presentation/webrtc_authority_loss_test.dart` (+2): the
  window pauses out of the room and restarts in full; it covers the web's
  second attempt.
* One existing expectation changed: `video_authority_suspension_test` 9
  expected ended-here right after a confirmed FINALIZAR because the fake's next
  read still said `ACTIVE`; it is now Idle (not live either way).

### Seen on a device

T10A (`LSTT10M2026081504`), shared backend on :3000 untouched (same PID before
and after), web console `main` (f88e9d3) served on `localhost:5173` in an
isolated Chrome driven over CDP, which also sampled `inbound-rtp` every second.
The tablet reached the backend through the dev tunnel's port 3010 and
`tool/realtime_harness/fault_relay.js` (new `holdCurrentMs`, every `/current`
numbered). Dart logs from the VM service; times relative to the cut, tablet
clock converted (-0.06 s).

```text
A  session 93479e12          video, ACTIVE, tap on Android.
B  5 s Wi-Fi, D1 fix only    suspended +0.37; Wi-Fi back +5.2; tablet peer FAILED
   (APK abf939d)             +15.3 (20 s window starts); web offer +16.1, lost (not
                             in the room); socket +19.9; confirmed +21.1; joined
                             +21.4; capture STOPPED +35.4; web offer +53.2 ->
                             Android dialog again. No stale answer this time: the
                             second defect alone.
B  5 s Wi-Fi, both fixes     session da1ddd06. Suspended +0.27; a re-read answered
   (APK 6b20c7d)             ACTIVE at +15.6 with the socket down: stayed suspended;
                             peer FAILED +16.7; web offer +16.0 lost; socket +18.8;
                             confirmed +20.3; joined +20.6 (45 s window starts);
                             web offer +53.0: "capture reused", no dialog; peer
                             connected +55.2; video and tap back. Web frames
                             27 -> 27 during the suspension.
C  9 s Wi-Fi                 suspended +0.19; Wi-Fi back +9.2; peer FAILED +16.9;
                             web offer +16.4 lost; socket +17.6; confirmed +19.8;
                             joined +20.1; web offer +53.2: capture reused; peer
                             connected +55.3; tap back. Frames 149 -> 149.
D  relay: socket closed,     re-read current#17 left +2.0 (served +3.1, answer held
   2.5 s block, next         12 s); socket +5.7; reconnection read current#18
   /current answer held 12 s confirmed +8.2, joined +8.5; current#17 delivered
                             +15.1: "read #13 overtaken: it repeats ..., nothing
                             changes". No re-suspension, no signaling reset, gate
                             not closed again; frames 174 -> 174 while suspended,
                             then 177, 179 ... 189, 191 across the late answer.
                             P2P stayed up throughout.
E  3 relay cuts 7 s apart,   cut 1's held re-read arrived during cut 2's
   each with a held read,    suspension: confirmed nothing. The reconnection read
   then 3+4+3 s Wi-Fi        of cut 2's socket (killed by cut 3) arrived after cut
                             3's confirmation: nothing changes. Wi-Fi: peer FAILED,
                             socket back, confirmed, joined; web offer lost by
                             0.33 s; next one 36.6 s after the rejoin: capture
                             reused, video and tap back.
F  FINALIZAR on the tablet   socket blocked 40 s by the relay. Ended here +0.12 s
   during the suspension     after the tap, peer closed, capture stopped +0.21 s;
                             POST close 200 CLOSED endedBy DEVICE; /current null
                             before and after the socket came back; no rejoin.
                             The held re-read answered before the tap (the poll
                             of the script missed it): an ACTIVE arriving after
                             FINALIZAR is covered by tests only.
G  SYSTEM (two ways)         CONNECTING never shared (dialog unanswered): backend
                             SYSTEM at 120 s; tablet withdrew at once and
                             abandoned the capture request; the stale dialog,
                             accepted later, started nothing ("capture start
                             abandoned"). ACTIVE, socket blocked 100 s, REST up:
                             frames 249 -> 249; backend SYSTEM 60.6 s after it
                             saw the socket go; tablet's re-read null at +63.9
                             (before its 75 s grace): peer and capture down; socket
                             back at +110: null, no rejoin. endedBy SYSTEM.
H  new assistance            session 735cf004: a new Android dialog, a new capture
                             (not reused), video, ACTIVE, tap.
```

`endedBy` read from the backend afterwards: 93479e12 TECHNICIAN, da1ddd06
DEVICE, 6073009b SYSTEM, 735cf004 SYSTEM.

Compared with S2 (Prompt 35, before both fixes): capture lost at 36.3 s and a
new consent; now B and C keep the same capture and recover at +55 s, with the
room joined once per reconnection and never left by a late answer.

### Residual risks

* **The web's first recovery offer is usually lost** after a Wi-Fi cut: its peer
  fails about when the tablet's does, before the tablet has rejoined, and the
  backend relays into a room the tablet is not in. Recovery then waits for the
  web's 30 s answer deadline + 5 s: ~53 s from the cut. A WEB change (offer
  again when the device's join notice arrives, or a shorter answer deadline)
  would cut that to seconds.
* **The 45 s window is coupled to WEB's constants** (30 s deadline, 5 s step).
  If both the first and the second offer are lost (outage over ~35 s after the
  web's failure), the third attempt (+15 s) may miss the window.
* **A rejoin restarts the window**: a socket that keeps flapping keeps a
  capture without receiver alive longer; every rejoin needs a fresh REST
  confirmation, and no frame leaves without a peer.
* **An ambiguous "no session"** (a read that may predate the session) suspends
  a confirmed session for one round trip and makes the device leave and rejoin
  the room; an offer sent in that gap is lost. Only possible when two reads
  overlap the creation of a session.
* **The proof that a session is over** assumes `/current` reflects one ordered
  history (one backend, one database). With read replicas a stale "no session"
  could end a live session early: failing safe, never granting.
* **An overtaken `ACTIVE` after an unconfirmed FINALIZAR** no longer causes an
  extra close; the owed close is sent again on the next cue that makes a fresh
  read, as before.
* **Unchanged:** detection of a half-open socket (up to ~45 s), the backend
  heartbeat and the connectivity watcher proposed by the audit, out of scope
  for this prompt. (Since then: BACKEND Prompt 36 and the heartbeat watchdog
  below.)

## Heartbeat watchdog (Prompt 42)

From the BACKEND Prompt 35 audit, after BACKEND Prompt 36 set the Engine.IO
heartbeat to 10 s / 10 s: a half-open `/devices` connection kept the session's
authority (commands and, since Prompt 40, the screen) until socket_io_client's
own `ping timeout`, `pingInterval + pingTimeout` = 20 s after the last `PING`.
The tablet now suspends **13 s** after the last `PING`, on a socket the
transport still calls connected.

### The signal

socket_io_client 3.1.6 does expose the heartbeat, one layer below the namespace
socket:

```text
engine Socket.onPacket('ping')   answers PONG, emitReserved('ping')
Manager.onping                   emitReserved('ping')        (manager.dart)
io.Socket.onPing(handler)        Manager.on('ping')          (darty.dart)
engine.pingInterval/pingTimeout  the Engine.IO OPEN packet of this connection
```

`SocketIoDeviceRealtimeClient` emits `RealtimeHeartbeat` for every `PING` of
its current socket (dropped for a released one, like every other callback) and
puts the handshake values on `RealtimeConnected.heartbeat`. No Socket.IO
application event is used: the backend has none for liveness (REALTIME.md,
"Heartbeat"). WebRTC and data-channel traffic prove nothing about `/devices`
and are not used.

The engine resets its own timer on *any* packet; the watchdog counts only the
connection coming up and each `PING`. The server sends the next `PING`
`pingInterval` after the previous `PONG` reached it, so on a healthy connection
the gap seen here is 10 s plus a round trip.

### Policy

```text
overdue   no PING for pingInterval + min(3 s, pingTimeout)    13 s with 10/10
stalled   no PING for pingInterval + pingTimeout + 5 s         25 s with 10/10
```

* The interval is never configured here: it comes from each handshake, so a
  backend with other values (the old 25/20 gives 28 s) is watched correctly.
  Without readable values a connection is not watched (the behaviour before
  this prompt); with 3.1.6 they are always there once the namespace accepted.
* The first `PING` of a connection is due `pingInterval` after the Engine.IO
  handshake, which precedes the namespace `connect`; the watch starts at the
  `connect`, so the first gap is never longer than the others (seen on the
  T10A: 5.5 s for a connection opened during a block).
* **3 s tolerance, measured**: 158 steady gaps on the T10A through the dev
  tunnel, median 10.11 s, p99 10.20 s, max 10.21 s; no false suspension in
  ~45 min. The margin covers the round trip and a busy isolate.

### Mechanism (`HeartbeatWatchdog`)

* **Evidence age** = the larger of the monotonic and the wall-clock interval.
  The Dart VM reads `CLOCK_MONOTONIC` on Android, which stops in deep sleep (so
  do Dart timers); the wall clock counts the sleep but can be set back. With
  the larger of both, neither sleeping nor setting the clock back makes old
  evidence look fresh; setting it forward can only suspend, then reconcile.
* **One timer, never periodic.** A `PING` only records the instant. The pending
  check fires at the previous deadline, measures the newest evidence and
  re-arms for what is left, so it decides from the real age whenever it runs,
  late or not, and never oscillates with the `PING` cycle.
* **One more turn** before declaring overdue (a zero-delay timer, queued behind
  anything the isolate already received), so a `PING` that arrived in time but
  waited behind the timer is counted.
* **Watches.** Every connection starts one; every loss, stop and generation ends
  it. Timers and callbacks carry the watch and do nothing for another one.
* `confirmFresh()` answers synchronously from the clocks; see "Commands".

### Authority: the existing C2 path, no second authority

`DeviceRealtimeBloc` reports `DeviceRealtimeHeartbeatOverdue`. Every coordinator
reads "connected" as `state is DeviceRealtimeConnected`, so for all of them it
is the channel going down:

```text
heartbeat overdue     RemoteSessionAuthorityChannelChanged(available: false,
                      heartbeatOverdue: true): suspended at once. Epoch moved,
                      commands refused, queue dropped, touch abandoned (DRAG
                      cancelled, never released), video gate closed, room left
                      locally, re-reads 2/4/8 s, 75 s grace started. Peer and
                      MediaProjection kept.
a PING on the same    DeviceRealtimeConnected again = "channel up", exactly as a
socket                reconnection. Nothing is granted: a GET /current that
                      STARTED after it must answer ACTIVE; only then is the
                      session confirmed, remote-session:join sent again (on the
                      same socket; the backend accepts a join of the joined
                      session) and the gate reopened.
transport gives up    DeviceRealtimeReconnecting, as always (20 s).
neither by 25 s       backstop: the socket is replaced (same token), so a stuck
                      transport cannot leave the tablet suspended for ever.
```

The states stay distinct: real disconnection (`Reconnecting`), suspicion
(`HeartbeatOverdue`, logged as "the realtime channel is silent"), recovery
pending (live, suspended), recovery confirmed (live, confirmed), definitive
close (`EndedLocally`, `ClosedRemotely`, `Idle`). FINALIZAR,
`remote-session:closed`, a "no session" answer and the 75 s grace win exactly
as before. The watchdog never sends a close, so a session the tablet gives up on
is still closed by the backend as `SYSTEM`.

The 60 s backend grace and the 75 s local grace are unchanged. With the watchdog
the tablet suspends up to ~7 s before the backend notices a half-open loss, so
its 75 s now end ~8 s (instead of ~15 s) after the backend's `SYSTEM` close; the
last re-read before the grace still lands after that close when REST is
reachable. Seen in G below.

UI: the connection line and the session headline say "Reconectando..." and the
control line "suspendido hasta confirmar con el servidor".

### Commands, and a tablet that runs late

The suspension reaches `WebRtcSessionBloc` a few event-loop turns after the
deadline, and after a deep sleep the timer itself may not have run yet. So right
before a command (tap, swipe, text, keys and every touch message) is let
through, `WebRtcSessionBloc` asks the same watchdog (`RealtimeLiveness`) and
refuses it with `session_not_active` if the evidence is too old; the declaration
follows by itself. When the app returns to the foreground the age is measured
again at once (`didChangeAppLifecycleState(resumed)` calls `checkNow`).

Android in the background: a remote session runs with a foreground service
(MediaProjection), so its process is not frozen like a cached app. Doze and the
deep sleep of a screen-off tablet stop the CPU, and with it Dart and the native
capture alike. What Dart cannot guarantee is a **live process whose isolate is
stalled** (a long jank, a debugger): the native capture keeps producing frames
and the gate stays as Dart last set it until Dart runs again. Proposed, not
implemented: a native lease on `ScreenCaptureTransmission` (Dart renews
`transmitUntil = elapsedRealtime + 13 s` on every `PING`; the gate closes
itself when it lapses, on `SystemClock.elapsedRealtime`, which counts sleep).
It needs its own JVM and device tests.

### Tests

* `test/features/device/domain/heartbeat_watchdog_test.dart` (24): handshake
  10/10 gives 13 s / 25 s, malformed values, tolerance clamp, 60 PINGs on one
  timer, late first PING, the 12.999/13 s edge, the extra turn, stalled once,
  repeated suspensions and recoveries, old watches, stop, no policy, a blocked
  isolate (late timer), deep sleep, the wall clock set back and forward.
* `test/features/device/presentation/device_realtime_heartbeat_test.dart` (10).
* `test/app/heartbeat_authority_watchdog_test.dart` (25), every bloc and
  coordinator real, covering the prompt's 30 cases. Without the overdue state 19
  fail; without the command check the two late-tablet ones fail.
* `test/integration/heartbeat_watchdog_isolated_test.dart` (4, opt-in with
  `HEARTBEAT_HARNESS=1`): the real socket_io_client against socket.io 4.8.1
  with a 2 s / 5 s heartbeat behind `half_open_relay.js`. Handshake values read,
  PINGs 2.01 s apart, overdue at +5.000 s against the transport's +7.003 s, a
  held PING bringing the same socket back, the one-way case.

### Seen on a device

2026-11-26, T10A (`LSTT10M2026081504`). Isolated environment, nothing shared
touched: a second installation `com.example.remote_control_device.p42test`
("P42 prueba vigilante", its own enrolment, device `877-208-548`), a
`git archive` of `remote_control_backend` `main` (18a413f, heartbeat 10/10)
with its own `node_modules` on 127.0.0.1:3200 and a disposable embedded
PostgreSQL, `remote_control_web` `main` (f88e9d3) built against it on
localhost:5173 in Chrome (`inbound-rtp` sampled each second), and
`tool/realtime_harness/half_open_relay.js` on port 3010 behind the Public dev
tunnel. WebRTC went P2P over the LAN, not through the relay. Dart logs from the
VM service; tablet clock -0.47 s, converted. PERMITIR, the capture dialog and
the accessibility toggle by the user; SOLICITAR, FINALIZAR, the enrolment input
and screen changes with adb; no mobile-mcp, no UiAutomation, no
`am force-stop`. Times from the cut; "PING" is the last one the tablet received.

```text
A  normal (whole run)        158 gaps: median 10.11 s, max 10.21 s. No suspension
                             but the induced ones; remote tap completed.
B  half-open 15 s, 7.0 s     suspended +5.99 (PING +13.00), gate closed +6.00;
   after a PING              transport disconnect +12.99 (PING +20.0), backend
                             OFFLINE ~+13. Restore: reconnected +0.33, REST
                             ACTIVE +0.65, rejoined, gate reopened. Web frames
                             1175 -> 1175 while suspended; 242 withheld natively.
C  half-open 25 s, 1.0 s     suspended +11.97 (PING +13.00), transport +18.97. A
   after a PING              re-read held by the cut answered ACTIVE with the
                             channel down: not confirmed. Restore: reconnected
                             +0.21, confirmed +0.68. Frames 1713 -> 1713.
D1 receives, cannot send     last PING +7.07; the server missed the PONG and
                             closed 10 s later; its close frame reached the
                             tablet and the transport disconnected at once
                             (+17.08, PING +10.0), before the watchdog.
D2 sends, cannot receive     suspended +10.98 (PING +13.00); transport and backend
                             OFFLINE +17.98, 7.0 s later. Frames 2429 -> 2429.
E  Wi-Fi off 5 s             Android closed the socket (+0.22, real disconnect);
   (svc wifi)                reconnected +14.0, confirmed and rejoined +14.5; web
                             recovery offer +16.1: capture reused, no dialog;
                             peer connected +16.4.
F  three cuts in a row       a PING held to 15.03 s (twice): overdue at 13 s, the
                             PING back on the SAME socket, REST, rejoin, gate
                             open, no disconnection; between them a 15 s
                             half-open recovered by reconnection. One suspension
                             per cut, nothing left over. A tap during a
                             suspension was refused ("La asistencia no está
                             activa en el dispositivo"); the next one, after it,
                             completed.
G  permanent (120 s)         suspended +11.96; backend OFFLINE ~+19, CLOSED
                             endedBy SYSTEM (DEVICE_ABSENT) +79; the tablet ended
                             at its 75 s (+86.97), capture stopped, no close sent;
                             after restore /current confirmed it gone, no rejoin.
H  FINALIZAR while           ended here 66 ms after the tap, capture stopped
   suspended (cut 60 s)      +0.2 s; the POST was held by the cut, timed out, and
                             was delivered on restore: CLOSED endedBy DEVICE.
                             /current confirmed it; no rejoin; projection 0.
I  new assistance            89b2d664 and 3ac56e79: PERMITIR and the capture dialog
                             again each time. 89b2d664 expired by the CONNECTING
                             TTL (SYSTEM) before the dialog was accepted;
                             3ac56e79 went ACTIVE with a new capture.
```

Unplanned: restarting the relay left the tunnel side half-open; the watchdog
suspended 13.01 s after the last `PING` and the transport noticed 7 s later.

Not shown on the device: a deep sleep or a stalled isolate during a session
(tests only), the stalled backstop (the transport always gave up first), a
backend with other heartbeat values.

### Residual risks

* **Detection is still bounded by the heartbeat**: up to 13 s after the last
  `PING` (3-13 s after a cut) instead of 20 s. Commands and the screen flow
  until then. Shorter needs a shorter `pingInterval` on the backend.
* **One-way loss where the tablet still receives** is detected by the server
  (its `pingTimeout`) and reached the tablet as a close frame 10 s after the
  last `PING` through the tunnel. Had the close frame been lost too, the
  watchdog would act at 13 s.
* **False suspension** when a `PING` is more than 3 s late (a congested network,
  an isolate blocked for seconds): costs one REST round trip and a rejoin; the
  peer and the capture are kept.
* **A stalled isolate in a live process** keeps the gate as it was; see the
  native lease proposed above.
* **The wall clock set forward** suspends once.
