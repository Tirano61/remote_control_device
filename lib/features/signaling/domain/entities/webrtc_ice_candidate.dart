import 'package:equatable/equatable.dart';

/// The `webrtc:ice-candidate` payload, exactly as `REALTIME.md` defines it.
///
/// The nullability here is the contract's, not a convenience:
///
/// ```text
/// candidate       string          required, max 1024, EMPTY IS VALID
/// sdpMid          string | null   optional, max 64
/// sdpMLineIndex   integer | null  optional, 0-255
/// ```
///
/// The empty `candidate` is accepted because some implementations use it to
/// signal end-of-candidates, and the two optional fields are nullable because
/// real WebRTC implementations produce them that way. Tightening either of
/// them here would make this client refuse candidates the backend accepts.
///
/// [toString] hides the candidate line: it carries host addresses and is one of
/// the values the contract says is never logged.
class WebRtcIceCandidate extends Equatable {
  const WebRtcIceCandidate({
    required this.remoteSessionId,
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  /// UUID of the session this candidate belongs to.
  final String remoteSessionId;

  /// The candidate line. May be empty; never `null`.
  final String candidate;

  /// May be absent. Sent explicitly as `null` when it is, which the contract
  /// allows and which keeps the wire shape of every candidate identical.
  final String? sdpMid;

  /// May be absent. `0-255` when present.
  final int? sdpMLineIndex;

  @override
  List<Object?> get props => [
    remoteSessionId,
    candidate,
    sdpMid,
    sdpMLineIndex,
  ];

  @override
  String toString() =>
      'WebRtcIceCandidate($remoteSessionId, '
      'candidate: ${candidate.length} chars)';
}
