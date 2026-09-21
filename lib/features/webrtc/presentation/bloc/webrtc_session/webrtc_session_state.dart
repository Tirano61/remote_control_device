part of 'webrtc_session_bloc.dart';

/// Where the peer connection with `remote_control_web` is.
///
/// A different thing from `RemoteSessionState`, and the difference is why this
/// file exists at all:
///
/// ```text
/// RemoteSession CONNECTING   a row in PostgreSQL, read over REST. It survives
///                            a dropped socket, a failed negotiation, a
///                            restart, and the tablet being asleep.
///
/// WebRtcConnected            a peer connection between two processes. It is
///                            never persisted, never read back from anywhere,
///                            and dies with the process that holds it.
/// ```
///
/// The two are deliberately allowed to disagree. The current backend has no
/// transition from `CONNECTING` to `ACTIVE` — the contract is explicit that
/// signaling never moves a session — so the normal, correct outcome of this
/// stage is a session that reads `CONNECTING` while the peer connection is
/// connected and the `control` channel is open. Nothing here writes a session
/// status, and nothing here asks the backend for one.
sealed class WebRtcSessionState extends Equatable {
  const WebRtcSessionState({this.screenCapture = ScreenCaptureStatus.idle});

  /// The remote session this negotiation belongs to, or `null` when there is
  /// no negotiation. Never adopted from a payload: it is the session the device
  /// is joined to and holds live over REST.
  String? get remoteSessionId => null;

  /// The `control` channel's state, once the peer has opened one.
  WebRtcDataChannelState? get controlChannel => null;

  /// Where screen sharing is.
  ///
  /// A third axis, independent of the other two and carried by every state
  /// including [WebRtcIdle] — because `MediaProjection` belongs to the remote
  /// session and not to the peer connection, and a negotiation that was
  /// abandoned leaves a capture running that the user can still see in their
  /// notification shade. A state that reported `idle` then would be lying to
  /// the one person who can see it is not.
  final ScreenCaptureStatus screenCapture;

  /// The success condition of this stage, and the whole of it:
  ///
  /// ```text
  /// PeerConnection connected  +  control DataChannel open
  /// ```
  ///
  /// No command has to have been exchanged — there is no control protocol yet.
  /// Deliberately *not* widened by screen capture: a user who declined the
  /// Android dialog has a working remote connection, and a technician holding
  /// an open control channel is connected whether or not a screen arrives.
  bool get isRemoteConnectionEstablished => false;

  @override
  List<Object?> get props => const [];
}

/// No peer connection, and none being built.
///
/// Where the application spends all of its time outside an assistance session,
/// and where every teardown lands: a closed remote session, a signaling channel
/// lost mid-negotiation, a dropped device credential. It says nothing about the
/// remote session, which only the backend moves.
final class WebRtcIdle extends WebRtcSessionState {
  const WebRtcIdle({super.screenCapture});

  @override
  List<Object?> get props => [screenCapture];
}

/// Shared shape of every state in which a negotiation exists or existed.
sealed class WebRtcNegotiation extends WebRtcSessionState {
  const WebRtcNegotiation(
    this.remoteSessionId, {
    this.controlChannel,
    super.screenCapture,
  });

  @override
  final String remoteSessionId;

  @override
  final WebRtcDataChannelState? controlChannel;

  @override
  List<Object?> get props => [remoteSessionId, controlChannel, screenCapture];
}

/// An offer was accepted: the peer connection is being created and the remote
/// description applied.
final class WebRtcPreparing extends WebRtcNegotiation {
  const WebRtcPreparing(
    super.remoteSessionId, {
    super.controlChannel,
    super.screenCapture,
  });
}

/// The remote description is applied and the answer is being created and
/// relayed.
final class WebRtcAnswering extends WebRtcNegotiation {
  const WebRtcAnswering(
    super.remoteSessionId, {
    super.controlChannel,
    super.screenCapture,
  });
}

/// The answer was delivered to the technician's namespace and ICE is being
/// exchanged. This is where a negotiation waits for connectivity to be found.
final class WebRtcConnecting extends WebRtcNegotiation {
  const WebRtcConnecting(
    super.remoteSessionId, {
    super.controlChannel,
    super.screenCapture,
  });
}

/// Every transport is connected.
///
/// Half of the success condition. The other half is [controlChannel] reaching
/// [WebRtcDataChannelState.open], which may happen before or after this — the
/// channel and the connection are separate facts and neither waits for the
/// other.
final class WebRtcConnected extends WebRtcNegotiation {
  const WebRtcConnected(
    super.remoteSessionId, {
    super.controlChannel,
    super.screenCapture,
  });

  @override
  bool get isRemoteConnectionEstablished =>
      controlChannel == WebRtcDataChannelState.open;
}

/// A transport dropped after having connected.
///
/// Treated as possibly transient, which is what WebRTC says it is: nothing is
/// closed, no timer is started and no renegotiation is asked for. It either
/// recovers on its own — and comes back as [WebRtcConnected] — or turns into
/// [WebRtcFailed], which is terminal.
final class WebRtcInterrupted extends WebRtcNegotiation {
  const WebRtcInterrupted(
    super.remoteSessionId, {
    super.controlChannel,
    super.screenCapture,
  });
}

/// The negotiation is over and its resources are released.
///
/// Reached from a failed transport, and from an answer that never reached the
/// technician. Nothing restarts from here on its own: a new negotiation needs a
/// new `webrtc:offer`, which only `remote_control_web` can send. That is the
/// whole loop protection — a device that renegotiated on failure would offer
/// against an end that is also offering.
final class WebRtcFailed extends WebRtcNegotiation {
  const WebRtcFailed(super.remoteSessionId, {super.screenCapture});
}

/// The peer connection closed, and this side did not ask for it.
///
/// Typically the technician's browser going away — a reload, a closed tab.
/// Like [WebRtcFailed] it waits: when the web app comes back it will join again
/// and create a new offer, and that offer is what starts the next negotiation.
final class WebRtcClosed extends WebRtcNegotiation {
  const WebRtcClosed(super.remoteSessionId, {super.screenCapture});
}
