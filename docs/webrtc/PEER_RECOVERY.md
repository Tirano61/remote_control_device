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
  transfer ownership). The same path is used after FAILED; it is to be confirmed
  on the tablet during the E2E below.

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

```text
adb logcat -c
adb logcat | grep -E "\[webrtc\]|\[screen\]|\[remote_control\]"
```

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
