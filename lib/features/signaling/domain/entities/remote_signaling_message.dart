import 'package:equatable/equatable.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_origin.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_answer.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_ice_candidate.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_offer.dart';

/// A `webrtc:*` message relayed to this device, already parsed and validated.
///
/// This is the whole API the WebRTC layer will consume: a peer connection built
/// in a later prompt subscribes to a `Stream<RemoteSignalingMessage>` and never
/// learns that Socket.IO, `DeviceRealtimeClient` or an ACK exist.
///
/// Nothing here is applied to anything yet. The messages are parsed, filtered
/// against the joined session and handed on; `setRemoteDescription`,
/// `createAnswer` and `addIceCandidate` belong to the prompt that introduces a
/// peer connection.
sealed class RemoteSignalingMessage extends Equatable {
  const RemoteSignalingMessage();

  /// The session the message claims to belong to. It is checked against the
  /// session this client actually joined before the message is delivered: a
  /// mismatch is discarded, never followed.
  String get remoteSessionId;

  /// Which end sent it. Added by the backend, so it cannot be forged by the
  /// peer — but it authorises nothing either. What authorises a message is the
  /// session it belongs to.
  SignalingOrigin get from;

  @override
  List<Object?> get props => const [];
}

/// `webrtc:offer` arrived.
final class OfferReceived extends RemoteSignalingMessage {
  const OfferReceived({required this.offer, required this.from});

  final WebRtcOffer offer;

  @override
  final SignalingOrigin from;

  @override
  String get remoteSessionId => offer.remoteSessionId;

  @override
  List<Object?> get props => [offer, from];
}

/// `webrtc:answer` arrived.
final class AnswerReceived extends RemoteSignalingMessage {
  const AnswerReceived({required this.answer, required this.from});

  final WebRtcAnswer answer;

  @override
  final SignalingOrigin from;

  @override
  String get remoteSessionId => answer.remoteSessionId;

  @override
  List<Object?> get props => [answer, from];
}

/// `webrtc:ice-candidate` arrived.
final class IceCandidateReceived extends RemoteSignalingMessage {
  const IceCandidateReceived({required this.candidate, required this.from});

  final WebRtcIceCandidate candidate;

  @override
  final SignalingOrigin from;

  @override
  String get remoteSessionId => candidate.remoteSessionId;

  @override
  List<Object?> get props => [candidate, from];
}
