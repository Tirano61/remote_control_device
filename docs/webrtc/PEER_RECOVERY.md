# Peer recovery — `remote_control_device`

What the tablet does when `remote_control_web` offers again for a session that
already has a peer connection on this side.

## The failure this fixes

Seen on the T10A during Prompt 23 WEB, E2E F:

```text
RemoteSession ACTIVE, authorised
web     PeerConnection FAILED
web     REST: the same session is still ACTIVE
web     closes the failed peer, builds a new one, sends webrtc:offer
device  its own peer still reads CONNECTED       (a dead remote end is only
                                                  noticed after ICE consent
                                                  checks time out)
device  "offer ignored: a peer connection is already connected"
web     "Esperando pantalla del dispositivo…" — forever
```

It only recovered once another socket reconnection happened. The rule that
caused it — never replace a CONNECTED peer — protected against duplicates and
stray relays, but it could not tell them from a genuine recovery, because the
offer carried nothing to tell them apart by.

## Telling offers apart

The signaling contract has no negotiation id: the backend forwards
`remoteSessionId` and `sdp` and drops everything else (see
`docs/backend/REALTIME.md`, `webrtc:offer`). What every offer does carry is its
SDP `o=` line:

```text
o=<username> <sess-id> <sess-version> <nettype> <addrtype> <unicast-address>
```

Every field but `sess-version` identifies the `RTCPeerConnection` that produced
it (RFC 8866 §5.2; browsers and libwebrtc pick a random 64-bit `sess-id` per
connection). `sess-version` grows when that same connection renegotiates.
`SdpOrigin` reads it; it is never logged.

`remote_control_web` builds a **new** `RTCPeerConnection` for every
negotiation (`WebRtcSessionBloc._onNegotiationRequested` → `createSession`) and
makes exactly one offer on it. So, per remote session:

| Offer | How it is recognised | What happens |
| --- | --- | --- |
| first | no peer on this side, connection never seen | answered (unchanged rules) |
| after FAILED / CLOSED here | no peer on this side, connection never seen | answered (unchanged rules) |
| recovery | a peer exists or is being built, connection never seen | **replaces the peer**, if the rule below holds |
| repeat | connection already answered, same SDP | ignored |
| stale | connection already answered, different SDP | ignored |
| renegotiation | same identity, other `sess-version` | ignored (the web never does it) |
| no readable `o=` | — | ignored |
| other session | `remoteSessionId` is not the joined one | ignored (SignalingBloc and the bloc) |

"Answered" means *accepted*: an origin is recorded the moment its offer is
accepted, so a relay of it handled while the first is still in flight is a
repeat. An offer that was **refused** (for example, authority suspended) is not
recorded and may be accepted later. The set is bounded (32) and emptied when the
live session changes.

## The recovery rule

An offer replaces an existing peer connection only if, at the moment it is
handled, all of this holds:

```text
the socket is joined to the offer's session             (as for any offer)
the backend holds that session live                     (as for any offer)
Android has not stopped the screen capture in it        (as for any offer)
its web connection was never answered in this session
the session's authority is CONFIRMED                    (new)
```

Confirmed authority comes from `RemoteSessionBloc` through the coordinator as
`WebRtcRemoteSessionAuthorityChanged`: a `CONNECTING` or `ACTIVE` session with
`RemoteSessionAuthority.confirmed`. Suspended, ended locally (FINALIZAR),
closed remotely or none all read as `null`. FINALIZAR, a remote close and a
revoked credential also make the session not live, which refuses every offer.

If any condition fails the offer is ignored, the old peer is left exactly as it
was (under the suspension rules if authority is suspended), and nothing is sent.

The technician's identity is not checked here because it cannot be: the backend
relays `webrtc:*` on `/devices` only from the technician that owns the session,
re-validated on every message. The tablet trusts the joined session and its own
REST view of it, never an id from a payload.

## Replacing the peer

In this order, and steps 1–4 synchronously, before anything is awaited:

```text
1. generation++        everything the old peer still reports — state, ICE,
                       data channels, control frames, acks — is dropped
2. discardPending()    a remote touch (DRAG) is abandoned, never released;
                       queued commands are refused; a gesture already running
                       on Android cannot be recalled and its ack is dropped
3. remote ICE queue    emptied: what was waiting belonged to the old offer
4. state Preparing     the offer, its SDP and its origin are recorded
5. close               old data channel, then old peer connection (awaited)
6. create              the new peer connection
7. negotiate           setRemoteDescription → queued ICE → screen → answer
8. control             only on the new channel, only when it is open, the
                       session ACTIVE and authority confirmed, checked per command
```

There is never more than one peer: `_peer` is cleared and the old one closed
before the factory is asked for a new one. Authorization is not carried over
from the old peer; it is re-evaluated for every command on the new channel.

Remote candidates the web trickles right after its offer arrive while the old
peer is still being closed and the new one built. They are queued for the new
peer (step 3 cleared the old ones) and applied once its remote description is
set. ICE flush loops are tracked per generation, so a loop of the old peer
still awaiting a send cannot keep the new one from draining.

## Screen capture

`MediaProjection` belongs to the remote session, not to the peer
(see [SCREEN_SHARING.md](SCREEN_SHARING.md#two-lifetimes-kept-apart)):

* **Still running** for this session: the capture client hands back the same
  track, no Android dialog, and it is attached to the new peer's offered video
  transceiver. Between the close and the attach the orphan-capture timer (20 s)
  runs; the attach cancels it.
* **Not running** (stopped by the orphan timer, never granted, denied): the
  recovery asks Android again, with the system dialog. Nothing restarts a
  capture without it.
* **Stopped by Android** (`onStop`) in this session: no offer is answered at
  all, recovery included; control stays withdrawn for that session.
* **Dialog still open** when the recovery arrives: the client already
  deduplicates requests for one session, so there is one dialog; the grant goes
  to the newest negotiation only.

## Races

| Race | Outcome |
| --- | --- |
| `remote-session:closed` while the recovery is being built | the close bumps the generation; the new peer is closed on arrival, never answered; capture stopped |
| FINALIZAR during the recovery | same: the session stops being live at once; no ICE leaves, capture stopped |
| two recovery offers in a row | the second supersedes the first before it is answered; the first's connection is now stale |
| old peer reports FAILED after the new one exists | dropped by generation |
| old ICE / old data channel / old control frames | dropped or closed by generation |
| authority confirmed → suspended during the recovery | the negotiation completes (the old peer is already gone, and a suspended peer is kept under the grace rules); no command runs until confirmed and ACTIVE again |
| capture permission granted late | goes to the current negotiation; to none if the session ended meanwhile |

Revocation always wins: every revocation path bumps the generation or makes the
session not live, and the offer flow re-checks the generation after every await.

## Residual risks and cross-repository dependencies

* **An answer already on the wire.** If the old negotiation's `webrtc:answer`
  was relayed just before the web replaced its connection, the web may receive
  it while its new connection waits for an answer. The device never sends an
  answer for a generation that is no longer current, but cannot recall one in
  flight. The web cannot tell answers apart either. Closing this needs a
  negotiation id in the signaling contract (`remote_control_backend`) echoed
  back in the answer — not implemented, not invented here.
* **A refused recovery leaves the web waiting.** If the offer is refused (for
  example the tablet's authority is suspended right after a reconnection), the
  web, which has no answer deadline today, waits until something else restarts
  its negotiation. An answer deadline on the web side would let it offer again
  once the tablet has confirmed; the tablet already accepts that new offer.
* **Several technician tabs.** Each tab builds its own connection. An offer from
  a second tab of the same technician is a valid recovery and replaces the
  first tab's peer: one peer at a time, but the last tab to offer wins.
* **Origins are SDP content.** A web client that reused an `RTCPeerConnection`
  for a second offer would be refused as a renegotiation. Today's web never
  does that; if it ever does, this rule has to learn renegotiation.
* **Reusing the track on a new peer** relies on the plugin not disposing a
  track it does not own when the old peer is closed (`replaceTrack` does not
  transfer ownership). Seen working on the T10A: three recoveries in a row on
  one capture (see "Seen on a device").
* **A real network cut is not scenario F.** Blocking the browser's UDP makes
  the tablet notice first (FAILED after ~18 s), so the web's later offer takes
  the ordinary "offer after FAILED" path. In that run the console also never
  offered again; that is the web's to investigate (see below).

## Tests

* `test/features/webrtc/domain/sdp_origin_test.dart` — reading the origin.
* `test/features/webrtc/presentation/webrtc_peer_recovery_test.dart` — the E2E F
  case, every offer kind, what the old peer leaves behind, the races and
  MediaProjection (with the real capture client over the fake platform where
  the number of consent dialogs matters).
* `test/app/webrtc_coordinator_test.dart` — E2E F through the real blocs and
  coordinators, and a recovery refused until a read after a reconnection
  confirms the session.

None of these is a device test.

## E2E on the T10A (to be run by hand)

Preconditions: debug build of this branch on the T10A (never the MDT1065), the
shared backend through the VS Code dev tunnel, the web console of Prompt 23 on
`localhost:5173`. No mobile-mcp, no UiAutomation; every consent (support
request, MediaProjection) is given by the user on the tablet.

Dart logs (`[webrtc]`, `[screen]`, `[remote-session]`) are `dart:developer`
records: read them from the VM service of a `flutter run` debug session, not
from logcat. Native ones (`RemoteControlScreen`, `RemoteControlInput`) are in
logcat.

1. Start an assistance and reach ACTIVE: video visible, a tap works.
2. Reproduce scenario F: make the web's peer fail while the tablet keeps its
   own (the same way as in Prompt 23 WEB E2E F).
3. Expected on the tablet, in order:
   `recovery offer accepted for <id>: replacing generation N`,
   `remote description applied`, `capture reused for <id>`,
   `video track attached`, `answer relayed`, `peer connection connected`,
   `control data channel open`. No `capture permission requested`.
4. Expected on the web: it leaves *Esperando pantalla del dispositivo…*, video
   returns, and control works only once the console shows the session
   authorised.
5. A tap, a swipe, a DRAG, BACK/HOME/RECENTS, SET_TEXT and IME_ENTER work on
   the new connection; nothing sent before the failure runs afterwards.
6. FINALIZAR on the tablet still ends everything at once.

## Seen on a device

Validated on 2026-11-18 on the T10A (`LSTT10M2026081504`, Android 16), debug
build of this branch (`1318c2f`, installed as an update with `flutter run`:
enrolment and credentials kept), against the backend `dist` of
`feature/backend-remote-session-lifecycle` (merged in `main` as `07b7c74`) through
the VS Code dev tunnel, and the console of `fix/web-remote-session-recovery`
(`0de681c`) served on `localhost:5173`. Both clients used the same STUN server.
PERMITIR and every MediaProjection consent were given by hand on the tablet; no
mobile-mcp, no UiAutomation. Tablet times from its Dart logs (the tablet's clock
runs ~0.36 s ahead of the PC), web and backend times from the PC.

Updating the APK disabled the accessibility service on the T10A; the user
enabled it again by hand.

### How scenario F was produced

A network cut cannot produce it (see "Residual risks"). The console's tab got a
test-only hook, injected from DevTools before the application started and never
part of `remote_control_web`: `window.RTCPeerConnection` wrapped so that
`connectionState` can be made to read `failed` and a `connectionstatechange`
dispatched. `dart_webrtc` reads `connectionState` in that handler, so the console
took its ordinary failure path — release the connection, check REST, build a
new one, offer — while its real connection and the tablet's were both
connected. No signaling was invented and nothing in the protocol changed; the
hook only decides when the console *believes* its connection failed.

### Recovery (session `cbf0eec8`, ACTIVE, authority confirmed)

```text
web     11:47:16.882  connection reads failed (real: connected); old one closed
web     11:47:18.877  REST confirmed the session; new RTCPeerConnection
tablet  11:46:52.988  last state of the old peer: connected (nothing after)
tablet  11:47:19.640  webrtc:offer received
        11:47:19.644  recovery offer accepted: replacing generation 4
        11:47:19.769  capture reused (no dialog), 19.789 video track attached
        11:47:20.160  answer relayed
        11:47:20.471  peer connection connected; 20.493 control channel open
web                   video back; "Control remoto: listo"
tablet  11:47:45.0    swipe completed; 47.5 recents, 49.9 back accepted by android
```

Twice more in the same session: generation 5 replaced at 11:48:21.690
(connected 22.478; swipe, home) and generation 6 at 11:48:54.050 (connected
56.034). Each web connection had its own origin (hashed `o=` identity:
`9c42395a`, `f445b50e`, `bce6af16`, …), every one `sess-version` 2: one offer
per connection, as the identification assumes. On the web never more than one
connection was not `closed`; on the tablet one peer at a time.

MediaProjection across the three recoveries: one projection
(`dumpsys media_projection`: TYPE_SCREEN_CAPTURE), one foreground service, the
capture started at 11:46:50 and never started again; the 20 s orphan window was
cancelled each time by the attach.

### Revocation during a recovery

```text
web     11:49:28.343  connection reads failed; FINALIZAR pressed 0.5 s later
tablet  11:49:31.431  recovery offer accepted: replacing generation 7
                      (relayed by the backend just before the close committed)
backend 11:49:30.862  CLOSED, endedBy TECHNICIAN
tablet  11:49:31.572  answer created
        11:49:32.042  remote-session:closed: control withdrawn
        11:49:32.050  negotiation closed; 32.131 capture stopped
        11:49:33.063  the answer in flight refused by the backend (unauthorized)
```

Revocation won: MediaProjection `null`, no foreground service, `InputDispatcher`
"no displays touched".

### Other runs

* **SYSTEM close** (session `30c77376`): with the console tab closed, the
  backend closed the session 60 s later (`endedBy SYSTEM`, 11:40:52.8);
  `remote-session:closed` reached the tablet at 11:40:53.9 and its negotiation
  was closed at once.
* **Network cut** (same session): Chrome's UDP blocked 11:33:37–11:35:08 with a
  temporary Windows Firewall rule (removed afterwards). Tablet: disconnected
  +7.8 s, failed +17.8 s, capture stopped at +37.8 s (orphan window). The
  console showed "No se pudo establecer la conexión" and sent no offer, neither
  during nor after the cut.
* **A new assistance afterwards** (session `6d74c6ea`): a first offer, with its
  own MediaProjection dialog; swipe completed. FINALIZAR on the tablet at
  12:05:29.295: negotiation closed +8 ms, capture stopped +206 ms; POST close
  200; backend CLOSED, `endedBy DEVICE`; nothing left running.

### Not shown on the device

* duplicate and stale offers, ICE and data channels of an old generation, and
  two offers in quick succession: the console never produces them and nothing
  was injected into signaling — covered by tests only;
* a DRAG held during a recovery, suspended authority during one, and FINALIZAR
  pressed on the tablet during one: tests only (suspension and the DRAG abandon
  were seen on the device in earlier prompts);
* SET_TEXT and IME_ENTER were not sent in these runs.
