import 'package:equatable/equatable.dart';

/// The `webrtc:answer` payload, exactly as `REALTIME.md` defines it.
///
/// Identical in shape, constraints and ACK to [WebRtcOffer]; only the event
/// name differs. It is modelled separately rather than shared so that a caller
/// cannot send an answer where an offer was meant, and so that each maps to one
/// event and one event only.
///
/// [toString] hides the SDP for the same reason it does on the offer.
class WebRtcAnswer extends Equatable {
  const WebRtcAnswer({required this.remoteSessionId, required this.sdp});

  /// UUID of the session this answer belongs to.
  final String remoteSessionId;

  /// The session description. 1–32768 characters per the contract.
  final String sdp;

  @override
  List<Object?> get props => [remoteSessionId, sdp];

  @override
  String toString() =>
      'WebRtcAnswer($remoteSessionId, sdp: ${sdp.length} chars)';
}
