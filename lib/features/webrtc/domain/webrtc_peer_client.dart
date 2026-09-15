import 'package:remote_control_device/features/webrtc/domain/entities/peer_ice_candidate.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_message.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_session_description.dart';

/// The boundary `flutter_webrtc` lives behind.
///
/// Everything above this file speaks in the types declared in
/// `features/webrtc/domain/entities`; `RTCPeerConnection`,
/// `RTCSessionDescription`, `RTCIceCandidate` and `RTCDataChannel` exist on the
/// other side of it and nowhere else. That is what lets the negotiation be
/// tested at all: WebRTC on Android is a native library that a unit test cannot
/// start, so the thing under test has to be able to run against a fake.
///
/// The port is also shaped by *who offers*. In this system:
///
/// ```text
/// remote_control_web      offerer,  creates the "control" data channel
/// remote_control_device   answerer, receives it
/// ```
///
/// which is why there is no `createOffer` and no `createDataChannel` here. They
/// are not omitted for brevity — a device able to create them is a device that
/// can end up negotiating against itself, and leaving them out of the port
/// makes that unrepresentable rather than merely discouraged.

/// Builds peer connections. One call, one connection: nothing is pooled or
/// reused, because a negotiation that failed must not leave anything behind for
/// the next one to inherit.
abstract interface class WebRtcPeerConnectionFactory {
  /// Creates a peer connection with [configuration] and no media of any kind.
  ///
  /// This build captures nothing — no camera, no microphone, no screen — so no
  /// track is ever added. Screen capture arrives with `MediaProjection`, in its
  /// own prompt, along with the permissions it needs.
  Future<WebRtcPeerConnection> create(WebRtcIceConfiguration configuration);
}

/// One peer connection, from creation to close.
///
/// The three streams are broadcast and start empty. They close when the
/// connection does, so a consumer that forgot to cancel a subscription stops
/// hearing anything rather than hearing a dead connection.
abstract interface class WebRtcPeerConnection {
  /// Every transition of the connection's own state.
  Stream<WebRtcConnectionState> get connectionStates;

  /// Every local candidate ICE gathering produced.
  ///
  /// They start arriving as soon as the local description is set, which is
  /// before the answer carrying it has been relayed. Holding them until it has
  /// is the caller's job, not this port's: a transport that buffered on its own
  /// would make the ordering untestable.
  Stream<PeerIceCandidate> get localIceCandidates;

  /// Data channels opened by the *peer*.
  ///
  /// The only way a channel reaches this device, and deliberately so. Which
  /// labels are acceptable, what happens to a second one and what happens to an
  /// unexpected one are decisions, and they are taken above this port.
  Stream<WebRtcDataChannel> get dataChannels;

  /// Applies the offer relayed from `remote_control_web`.
  ///
  /// The SDP is applied exactly as received — never edited, reordered or
  /// filtered. Remote candidates may only be added after this completes, which
  /// is why the caller queues the ones that arrive first.
  Future<void> setRemoteDescription(WebRtcSessionDescription description);

  /// Produces the answer. Does **not** apply it — [setLocalDescription] does,
  /// and keeping them apart is what makes the order of the two observable.
  Future<WebRtcSessionDescription> createAnswer();

  /// Applies the answer locally. Local ICE gathering starts here.
  Future<void> setLocalDescription(WebRtcSessionDescription description);

  /// Adds a candidate relayed from the peer.
  ///
  /// The candidate line is passed through unchanged. An end-of-candidates
  /// marker — the empty line the contract allows — is handled inside the
  /// implementation, because what it has to become is a `flutter_webrtc`
  /// detail and no layer above should have to know it.
  Future<void> addRemoteIceCandidate(PeerIceCandidate candidate);

  /// Closes and releases everything this connection holds.
  ///
  /// Idempotent: calling it on an already-closed connection is not an error.
  /// Several paths lead here — a failed negotiation, a closed remote session, a
  /// dropped credential — and none of them can be sure it is first.
  Future<void> close();
}

/// A data channel opened by the peer.
abstract interface class WebRtcDataChannel {
  /// The label the peer gave it. Only `control` is accepted by this build.
  String get label;

  /// Whether the peer created it with ordered delivery. Read for diagnostics;
  /// a channel is never refused over it.
  bool get ordered;

  /// The state at the moment of reading, for a channel that may already have
  /// opened before anyone subscribed to [states].
  WebRtcDataChannelState get state;

  /// Every transition of the channel's state.
  Stream<WebRtcDataChannelState> get states;

  /// Frames from the peer, unparsed.
  ///
  /// Exposed so that a silent channel can be told from a working one. Nothing
  /// in this build interprets a frame, and nothing acts on one.
  Stream<WebRtcDataChannelMessage> get messages;

  /// Closes the channel. Idempotent, for the same reason as above.
  Future<void> close();
}
