import 'package:remote_control_device/features/signaling/domain/entities/signaling_relay_result.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_answer.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_ice_candidate.dart';

/// The only way out of the WebRTC feature.
///
/// Two messages, because an answerer sends exactly two kinds: the answer to the
/// offer it was given, and its own ICE candidates. There is no `sendOffer`
/// here — the device does not offer — and no join, because joining a session's
/// signaling room is the signaling feature's business and happens whether a
/// peer connection exists or not.
///
/// It returns the contract's own [SignalingRelayResult] rather than a boolean.
/// The distinction matters: `delivered: true` means the backend handed the
/// message to the technician's namespace, while every other outcome — refused,
/// unanswered, never sent — means the peer cannot have received it, and an
/// answerer whose answer did not arrive is not negotiating with anybody.
abstract interface class WebRtcSignalingGateway {
  /// Relays `webrtc:answer`.
  Future<SignalingRelayResult> sendAnswer(WebRtcAnswer answer);

  /// Relays `webrtc:ice-candidate`.
  Future<SignalingRelayResult> sendIceCandidate(WebRtcIceCandidate candidate);
}
