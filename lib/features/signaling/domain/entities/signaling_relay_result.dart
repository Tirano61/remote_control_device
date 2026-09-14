import 'package:equatable/equatable.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_error_code.dart';

/// Why a `webrtc:*` message never reached the socket.
enum SignalingNotSentReason {
  /// This client is not joined to that session, so sending would be answered
  /// `NOT_JOINED` anyway. The contract makes `remote-session:join` mandatory
  /// before any `webrtc:*`, and this is that rule enforced locally.
  notJoined,

  /// The payload does not satisfy the documented DTO — an SDP that is empty or
  /// past 32768 characters, a candidate past 1024, an `sdpMid` past 64, an
  /// `sdpMLineIndex` outside `0-255`, or a session id that is not a UUID.
  /// Emitting it could only earn an `INVALID_PAYLOAD`.
  invalidPayload,
}

/// What a `webrtc:offer` / `webrtc:answer` / `webrtc:ice-candidate` produced.
///
/// The contract's `SignalingRelayAck` has two shapes; two more exist here for
/// what a client has to represent on its own — an answer that never came, and a
/// message this client refused to put on the wire.
sealed class SignalingRelayResult extends Equatable {
  const SignalingRelayResult();

  @override
  List<Object?> get props => const [];
}

/// `{ "delivered": true, "remoteSessionId": "..." }`.
///
/// It means the backend handed the message to the peer's namespace — and
/// **nothing more**. It does not mean a technician was connected, that anybody
/// received it, or that an SDP was processed. If the other end has not joined,
/// the room is empty and the message is dropped silently; signaling is never
/// buffered or retried.
final class SignalingRelayDelivered extends SignalingRelayResult {
  const SignalingRelayDelivered(this.remoteSessionId);

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// `{ "delivered": false, "error": "..." }`, with one of the documented codes.
final class SignalingRelayRefused extends SignalingRelayResult {
  const SignalingRelayRefused(this.error);

  final SignalingErrorCode error;

  @override
  List<Object?> get props => [error];
}

/// No usable ACK: the socket was not connected, the answer did not arrive
/// before the timeout, or it was not a `SignalingRelayAck`.
final class SignalingRelayUnanswered extends SignalingRelayResult {
  const SignalingRelayUnanswered();
}

/// The message never left this client.
final class SignalingRelayNotSent extends SignalingRelayResult {
  const SignalingRelayNotSent(this.reason);

  final SignalingNotSentReason reason;

  @override
  List<Object?> get props => [reason];
}
