import 'package:equatable/equatable.dart';

/// The `webrtc:offer` payload, exactly as `REALTIME.md` defines it.
///
/// Two fields, no more: the backend rejects an unknown property outright, and
/// renaming one to read better in Dart would make the contract impossible to
/// check against the document. The offer/answer distinction lives entirely in
/// the event name — the backend never parses the SDP.
///
/// [toString] is overridden on purpose. The contract states that SDP is never
/// written to the backend logs, and the same rule holds here: an accidental
/// `print`, a bloc observer or an error report must not be able to spill the
/// session description.
class WebRtcOffer extends Equatable {
  const WebRtcOffer({required this.remoteSessionId, required this.sdp});

  /// UUID of the session this offer belongs to. Always a value that came back
  /// from an authenticated backend answer, never one built locally.
  final String remoteSessionId;

  /// The session description. 1–32768 characters per the contract.
  final String sdp;

  @override
  List<Object?> get props => [remoteSessionId, sdp];

  @override
  String toString() => 'WebRtcOffer($remoteSessionId, sdp: ${sdp.length} chars)';
}
