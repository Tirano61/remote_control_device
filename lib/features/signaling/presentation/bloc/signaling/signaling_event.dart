part of 'signaling_bloc.dart';

sealed class SignalingEvent extends Equatable {
  const SignalingEvent();

  @override
  List<Object?> get props => const [];
}

/// Both conditions the contract requires are met: the socket is up and the
/// backend holds a live remote session with this id. Join it.
///
/// Raised by `SignalingCoordinator` — never by a widget. The id comes from a
/// remote session that was read over an authenticated REST call, never from a
/// realtime payload and never from the UI, so this event can only ever name a
/// session the backend already told this device it owns.
///
/// Idempotent by design. The same session is announced several times over the
/// life of a connection — a realtime reconnect, a `remote-session:created`, a
/// support request reaching `ACCEPTED` all cause the session to be re-read —
/// and none of that may produce a second concurrent join.
final class SignalingJoinRequested extends SignalingEvent {
  const SignalingJoinRequested(this.remoteSessionId);

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// The realtime channel is no longer connected.
///
/// Socket.IO rooms do not survive a socket, so whatever was joined is gone
/// whether this client acknowledges it or not. Pretending otherwise would mean
/// emitting `webrtc:*` that can only be answered `NOT_JOINED`.
///
/// It says nothing about the remote session, which the backend keeps exactly
/// as it was: a dropped socket never ends an assistance session.
final class SignalingConnectionLost extends SignalingEvent {
  const SignalingConnectionLost();
}

/// There is no live remote session to be joined to any more — it closed, the
/// device identity was dropped, or the backend answered that there is none.
///
/// The previous signaling state is cleared so that the next join can only ever
/// use the next session's id.
final class SignalingSessionEnded extends SignalingEvent {
  const SignalingSessionEnded();
}

/// A `webrtc:*` was answered `NOT_JOINED`: the socket is not in the room this
/// client believed it was in.
///
/// The contract's own instruction is to go back through `remote-session:join`,
/// which is what this does. The message that was refused is **not** resent —
/// signaling is ephemeral by design, and re-sending on the client's own
/// initiative is how a retry loop starts.
final class SignalingJoinLost extends SignalingEvent {
  const SignalingJoinLost(this.remoteSessionId);

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// A `webrtc:*` was answered `UNAUTHORIZED`: the session this client believes
/// it is relaying for does not exist, is `CLOSED`, or is not this device's.
///
/// Every relayed message is re-validated on delivery, so this is the backend
/// saying the session moved on while the room membership stayed behind.
/// Re-joining would earn the same answer, so signaling stops for this session
/// and the remote session is reconciled over REST instead.
final class SignalingRelayDenied extends SignalingEvent {
  const SignalingRelayDenied(this.remoteSessionId);

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// Try the join again although nothing about the socket or the session has
/// changed.
///
/// The one deliberate way out of [SignalingUnavailable], kept separate from
/// [SignalingJoinRequested] precisely so that an automatic re-announcement of
/// the same session can never take this path.
final class SignalingRetryRequested extends SignalingEvent {
  const SignalingRetryRequested();
}
