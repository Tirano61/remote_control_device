import 'package:equatable/equatable.dart';

/// Which half of the negotiation a description is.
///
/// Both exist although this build only ever *creates* an answer: the offer
/// arrives from `remote_control_web` and has to be applied, so the type has to
/// be able to say which it is.
enum WebRtcSdpKind {
  /// Created by `remote_control_web` and applied here as the remote
  /// description. This device never creates one.
  offer,

  /// Created here in reply to an offer, applied here as the local description
  /// and relayed back over `webrtc:answer`.
  answer,
}

/// An SDP and what kind of description it is.
///
/// The SDP is carried opaquely and is never inspected, rewritten or trimmed —
/// munging it is how a negotiation that "almost works" is built. It is also
/// never printed: the contract lists SDP among the values that are not logged,
/// and [toString] keeps that true even through an accidental interpolation.
class WebRtcSessionDescription extends Equatable {
  const WebRtcSessionDescription({required this.kind, required this.sdp});

  const WebRtcSessionDescription.offer(String sdp)
    : this(kind: WebRtcSdpKind.offer, sdp: sdp);

  const WebRtcSessionDescription.answer(String sdp)
    : this(kind: WebRtcSdpKind.answer, sdp: sdp);

  final WebRtcSdpKind kind;

  /// Exactly as produced by WebRTC or as relayed by the backend.
  final String sdp;

  @override
  List<Object?> get props => [kind, sdp];

  @override
  String toString() =>
      'WebRtcSessionDescription(${kind.name}, ${sdp.length} chars)';
}
