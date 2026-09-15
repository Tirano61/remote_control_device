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

/// `{ "joined": true, "remoteSessionId": "...", "peerJoined": true|false }`.
///
/// The socket is now in the session's room in the `/devices` namespace, and
/// `webrtc:*` is allowed for this session — until the socket drops, at which
/// point the join is gone with it.
final class RemoteSessionJoined extends JoinRemoteSessionResult {
  const RemoteSessionJoined(this.remoteSessionId, {required this.peerJoined});

  /// Echoed by the backend. It is checked against the id that was asked for:
  /// an answer about another session is not an answer to this request.
  final String remoteSessionId;

  /// Whether the technician's socket was already in the same session room when
  /// this join was accepted.
  ///
  /// Readiness, and readiness only. It is recorded and shown; it never starts a
  /// negotiation on this side, because the device is the answerer and a device
  /// that created a peer connection on learning this would make both ends
  /// offer. What starts a negotiation here is one thing: `webrtc:offer`.
  ///
  /// It is never defaulted. A `true` invented locally would claim the peer is
  /// reachable when nothing said so, and a `false` would contradict an ACK
  /// this build simply failed to read — so an ACK without a usable boolean is
  /// [RemoteSessionJoinUnanswered] instead.
  final bool peerJoined;

  @override
  List<Object?> get props => [remoteSessionId, peerJoined];
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
