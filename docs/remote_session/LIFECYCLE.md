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
The user of the tablet can end the assistance here without asking anyone.
```

## States

`RemoteSessionBloc` emits one of these:

| State | Meaning | Control | Peer / screen |
| --- | --- | --- | --- |
| `RemoteSessionInitial` / `Loading` | not asked yet / first read in flight | no | no |
| `RemoteSessionIdle` | the backend says there is no live session | no | no |
| `RemoteSessionConnecting` | backend `CONNECTING` | no (`session_not_active`) | may negotiate |
| `RemoteSessionActive` | backend `ACTIVE` | yes, on the current channel | yes |
| `RemoteSessionEndedLocally` | the user pressed FINALIZAR; see below | **no** | **torn down** |
| `RemoteSessionUnavailable` | the first read failed: unknown, not "none" | no | no |

`RemoteSessionLive` (`Connecting` or `Active`) is the only family the coordinators
read as "an assistance exists". `RemoteSessionEndedLocally` is deliberately not in
it.

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
close lands or the technician presses FINALIZAR on their side. A server-side
timeout (`SYSTEM` close on abandonment) is the backend's to add; this client does
not rely on one.

## The technician's FINALIZAR

Unchanged: `remote-session:closed` causes a read, the empty answer moves the
state to `Idle`, and the same `WebRtcRemoteSessionChanged(null)` teardown runs,
in the same order.

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
