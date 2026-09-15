import 'package:equatable/equatable.dart';

/// An ICE candidate as a peer connection produces or consumes it.
///
/// The same three fields the signaling contract carries, minus the one a peer
/// connection has no business knowing:
///
/// ```text
/// WebRtcIceCandidate    signaling: remoteSessionId + candidate + sdpMid + index
/// PeerIceCandidate      WebRTC:                      candidate + sdpMid + index
/// ```
///
/// Dropping `remoteSessionId` is the point. A peer connection is a transport
/// between two endpoints and knows nothing about remote sessions; attaching the
/// session id to it would let a candidate arriving on one negotiation be
/// relayed for another. Pairing a candidate with a session is a decision, and
/// it is taken once, in the bloc that owns both.
///
/// [candidate] may be empty. The contract calls that the end-of-candidates
/// signal, and so does WebRTC; what an empty line means to `flutter_webrtc` is
/// the data layer's problem and is handled there.
///
/// [toString] hides the line: it carries host addresses, and the contract lists
/// ICE candidates among the values never written to a log.
class PeerIceCandidate extends Equatable {
  const PeerIceCandidate({
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  /// The candidate line. May be empty; never `null`.
  final String candidate;

  /// May be absent — real WebRTC implementations produce it that way.
  final String? sdpMid;

  /// May be absent. `0-255` when the contract carries it.
  final int? sdpMLineIndex;

  /// Whether this is the end-of-candidates marker rather than a candidate.
  bool get isEndOfCandidates => candidate.isEmpty;

  @override
  List<Object?> get props => [candidate, sdpMid, sdpMLineIndex];

  @override
  String toString() =>
      'PeerIceCandidate(${candidate.length} chars, '
      'mid: $sdpMid, index: $sdpMLineIndex)';
}
