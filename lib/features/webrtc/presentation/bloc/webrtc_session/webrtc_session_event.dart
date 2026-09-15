part of 'webrtc_session_bloc.dart';

sealed class WebRtcSessionEvent extends Equatable {
  const WebRtcSessionEvent();

  @override
  List<Object?> get props => const [];
}

// ------------------------------------------------------------------ inbound

/// `webrtc:offer` arrived for the session this device is joined to.
///
/// The one and only thing that creates a peer connection here. Not a connected
/// socket, not a live remote session, not `peerJoined`, not a technician being
/// ready — those are all preconditions the offer is checked *against*, never
/// triggers of their own.
///
/// The reason is the negotiation role. `remote_control_web` is the offerer for
/// this system; if the device also created a connection whenever it thought the
/// time was right, both ends would produce an offer and the two would collide.
/// An answerer that starts at the offer cannot do that.
final class WebRtcOfferReceived extends WebRtcSessionEvent {
  const WebRtcOfferReceived(this.offer);

  final WebRtcOffer offer;

  @override
  List<Object?> get props => [offer];
}

/// `webrtc:ice-candidate` arrived from the technician.
///
/// May arrive before the offer has finished being applied — the web sends its
/// candidates as soon as its own offer was delivered, without waiting for this
/// side — so it is queued rather than dropped when there is no remote
/// description yet.
final class WebRtcRemoteIceReceived extends WebRtcSessionEvent {
  const WebRtcRemoteIceReceived(this.candidate);

  final WebRtcIceCandidate candidate;

  @override
  List<Object?> get props => [candidate];
}

// ------------------------------------------------------------ preconditions

/// The signaling room membership changed: [remoteSessionId] is the session this
/// device may relay for, or `null` when it may not relay at all.
///
/// Losing it mid-negotiation ends that negotiation: an answerer that cannot
/// send its answer or its candidates has nothing to finish with, and the web
/// will offer again after its own rejoin. Losing it *after* the connection is
/// up changes nothing — WebRTC is peer-to-peer and does not need the socket
/// that introduced the two ends.
final class WebRtcSignalingAvailabilityChanged extends WebRtcSessionEvent {
  const WebRtcSignalingAvailabilityChanged(this.remoteSessionId);

  final String? remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// The backend's remote session changed: [remoteSessionId] is the live session
/// — `CONNECTING` or `ACTIVE` — or `null` when there is none.
///
/// `null` is a full teardown. A peer connection must never outlive the
/// assistance that authorised it, and the backend is the only thing that says
/// whether the assistance is still on.
final class WebRtcRemoteSessionChanged extends WebRtcSessionEvent {
  const WebRtcRemoteSessionChanged(this.remoteSessionId);

  final String? remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

// -------------------------------------------------------------- from a peer

/// Internal. A callback from a peer connection, tagged with the generation that
/// produced it.
///
/// Generations exist because a peer connection's callbacks outlive the decision
/// to abandon it: a connection that failed while its replacement was being
/// created will still report state, and applying that to the replacement would
/// kill a negotiation that is perfectly healthy. Everything late is compared
/// against the current generation and dropped.
sealed class WebRtcPeerEvent extends WebRtcSessionEvent {
  const WebRtcPeerEvent(this.generation);

  final int generation;

  @override
  List<Object?> get props => [generation];
}

/// ICE gathering produced a local candidate.
final class WebRtcLocalIceProduced extends WebRtcPeerEvent {
  const WebRtcLocalIceProduced(super.generation, this.candidate);

  final PeerIceCandidate candidate;

  @override
  List<Object?> get props => [generation, candidate];
}

/// The peer connection's own state moved.
final class WebRtcConnectionStateChanged extends WebRtcPeerEvent {
  const WebRtcConnectionStateChanged(super.generation, this.connectionState);

  final WebRtcConnectionState connectionState;

  @override
  List<Object?> get props => [generation, connectionState];
}

/// The peer opened a data channel. Which one is kept — if any — is decided in
/// the bloc; nothing is adopted merely because it arrived.
final class WebRtcDataChannelOffered extends WebRtcPeerEvent {
  const WebRtcDataChannelOffered(super.generation, this.channel);

  final WebRtcDataChannel channel;

  @override
  List<Object?> get props => [generation, channel];
}

/// The accepted `control` channel's state moved.
final class WebRtcDataChannelStateChanged extends WebRtcPeerEvent {
  const WebRtcDataChannelStateChanged(super.generation, this.channelState);

  final WebRtcDataChannelState channelState;

  @override
  List<Object?> get props => [generation, channelState];
}
