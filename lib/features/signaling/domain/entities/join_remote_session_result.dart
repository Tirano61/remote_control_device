import 'package:equatable/equatable.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_error_code.dart';

/// What `remote-session:join` answered.
///
/// The contract's `JoinRemoteSessionAck` has two shapes; this type has three,
/// because a client also has to represent the case the ACK never came. The
/// backend always answers its ACKs, so [RemoteSessionJoinUnanswered] means the
/// socket went away or the answer was not the documented shape — never "the
/// backend ignored us".
sealed class JoinRemoteSessionResult extends Equatable {
  const JoinRemoteSessionResult();

  @override
  List<Object?> get props => const [];
}

/// `{ "joined": true, "remoteSessionId": "..." }`.
///
/// The socket is now in the session's room in the `/devices` namespace, and
/// `webrtc:*` is allowed for this session — until the socket drops, at which
/// point the join is gone with it.
final class RemoteSessionJoined extends JoinRemoteSessionResult {
  const RemoteSessionJoined(this.remoteSessionId);

  /// Echoed by the backend. It is checked against the id that was asked for:
  /// an answer about another session is not an answer to this request.
  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// `{ "joined": false, "error": "..." }`.
///
/// `REALTIME.md` documents `INVALID_PAYLOAD` and `UNAUTHORIZED` for this event.
/// Any other documented code reaches here too rather than being reinterpreted,
/// and one this build does not know arrives as [SignalingErrorCode.unknown].
final class RemoteSessionJoinRefused extends JoinRemoteSessionResult {
  const RemoteSessionJoinRefused(this.error);

  final SignalingErrorCode error;

  @override
  List<Object?> get props => [error];
}

/// No usable ACK: the socket was not connected, the answer did not arrive
/// before the timeout, or what arrived was not a `JoinRemoteSessionAck`.
///
/// Deliberately distinct from a refusal. A refusal is the backend's verdict on
/// this session; this is the absence of one, and the two must not lead to the
/// same reaction.
final class RemoteSessionJoinUnanswered extends JoinRemoteSessionResult {
  const RemoteSessionJoinUnanswered();
}
