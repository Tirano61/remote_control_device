import 'package:remote_control_device/features/signaling/data/signaling_events.dart';
import 'package:remote_control_device/features/signaling/domain/entities/join_remote_session_result.dart';
import 'package:remote_control_device/features/signaling/domain/entities/remote_signaling_message.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_error_code.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_origin.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_relay_result.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_answer.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_ice_candidate.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_offer.dart';

/// The only place that knows how a signaling payload is spelled on the wire.
///
/// Two directions, two different rules, on purpose:
///
/// ```text
/// outgoing   validated against the documented DTO before it is emitted.
///            A payload the backend would answer INVALID_PAYLOAD is not put on
///            the socket at all.
///
/// incoming   validated for shape only.
///            Size limits are the backend's to enforce, and it already has;
///            re-imposing them here would make this build reject a payload a
///            later backend legitimately allows.
/// ```
///
/// Nothing here logs, and nothing here throws: an unreadable payload produces
/// `null` and a caller that drops it. A realtime payload is untrusted input
/// shaped by whatever is on the other end of the socket.

/// `@IsUUID()` on the backend accepts any version, so this does too.
final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

bool _isSessionId(Object? value) => value is String && _uuid.hasMatch(value);

// ---------------------------------------------------------------- outgoing

/// `{ "remoteSessionId": "..." }` — and nothing else.
///
/// The contract is explicit that `remoteSessionId` is the only accepted
/// property and that any extra one makes the payload invalid. In particular the
/// participant is never sent: the backend derives it from the namespace the
/// socket connected through.
///
/// Returns `null` when the id is not a UUID, which is the one thing that could
/// make this payload invalid. That can only happen if an id were built locally
/// instead of read from an authenticated backend answer.
Map<String, dynamic>? buildRemoteSessionJoinPayload(String remoteSessionId) {
  if (!_isSessionId(remoteSessionId)) return null;
  return <String, dynamic>{'remoteSessionId': remoteSessionId};
}

/// `{ "remoteSessionId": "...", "sdp": "..." }`.
Map<String, dynamic>? buildWebRtcOfferPayload(WebRtcOffer offer) =>
    _buildSessionDescriptionPayload(offer.remoteSessionId, offer.sdp);

/// `{ "remoteSessionId": "...", "sdp": "..." }` — the same shape as an offer.
Map<String, dynamic>? buildWebRtcAnswerPayload(WebRtcAnswer answer) =>
    _buildSessionDescriptionPayload(answer.remoteSessionId, answer.sdp);

Map<String, dynamic>? _buildSessionDescriptionPayload(
  String remoteSessionId,
  String sdp,
) {
  if (!_isSessionId(remoteSessionId)) return null;
  if (sdp.length < minSdpLength || sdp.length > maxSdpLength) return null;
  return <String, dynamic>{'remoteSessionId': remoteSessionId, 'sdp': sdp};
}

/// `{ "remoteSessionId", "candidate", "sdpMid", "sdpMLineIndex" }`.
///
/// Both optional fields are always written, explicitly as `null` when absent.
/// The contract allows either form — omitted or `null` — and always sending
/// both keys means every candidate leaves this client with the same shape,
/// which is one fewer thing to reason about when a relay is refused.
Map<String, dynamic>? buildWebRtcIceCandidatePayload(
  WebRtcIceCandidate candidate,
) {
  if (!_isSessionId(candidate.remoteSessionId)) return null;
  // The empty candidate is valid: it is how end-of-candidates is signalled.
  if (candidate.candidate.length > maxIceCandidateLength) return null;

  final sdpMid = candidate.sdpMid;
  if (sdpMid != null && sdpMid.length > maxSdpMidLength) return null;

  final sdpMLineIndex = candidate.sdpMLineIndex;
  if (sdpMLineIndex != null &&
      (sdpMLineIndex < minSdpMLineIndex || sdpMLineIndex > maxSdpMLineIndex)) {
    return null;
  }

  return <String, dynamic>{
    'remoteSessionId': candidate.remoteSessionId,
    'candidate': candidate.candidate,
    'sdpMid': sdpMid,
    'sdpMLineIndex': sdpMLineIndex,
  };
}

// -------------------------------------------------------------------- ACKs

/// Reads a `JoinRemoteSessionAck`:
///
/// ```json
/// { "joined": true,  "remoteSessionId": "..." }
/// { "joined": false, "error": "UNAUTHORIZED" }
/// ```
///
/// Anything else — no answer, a non-object, `joined` missing, or `joined: true`
/// without a usable id — is [RemoteSessionJoinUnanswered]. A malformed ACK is
/// the absence of a verdict, and must not be read as one.
JoinRemoteSessionResult parseJoinRemoteSessionAck(Object? ack) {
  if (ack is! Map) return const RemoteSessionJoinUnanswered();

  final joined = ack['joined'];
  if (joined == true) {
    final remoteSessionId = ack['remoteSessionId'];
    if (remoteSessionId is! String || remoteSessionId.isEmpty) {
      return const RemoteSessionJoinUnanswered();
    }
    return RemoteSessionJoined(remoteSessionId);
  }
  if (joined == false) {
    return RemoteSessionJoinRefused(parseSignalingErrorCode(ack['error']));
  }
  return const RemoteSessionJoinUnanswered();
}

/// Reads a `SignalingRelayAck`:
///
/// ```json
/// { "delivered": true,  "remoteSessionId": "..." }
/// { "delivered": false, "error": "NOT_JOINED" }
/// ```
SignalingRelayResult parseSignalingRelayAck(Object? ack) {
  if (ack is! Map) return const SignalingRelayUnanswered();

  final delivered = ack['delivered'];
  if (delivered == true) {
    final remoteSessionId = ack['remoteSessionId'];
    if (remoteSessionId is! String || remoteSessionId.isEmpty) {
      return const SignalingRelayUnanswered();
    }
    return SignalingRelayDelivered(remoteSessionId);
  }
  if (delivered == false) {
    return SignalingRelayRefused(parseSignalingErrorCode(ack['error']));
  }
  return const SignalingRelayUnanswered();
}

/// The documented error codes, which the contract calls its stable part. A code
/// this build has never seen becomes [SignalingErrorCode.unknown] rather than
/// being guessed at or crashing.
SignalingErrorCode parseSignalingErrorCode(Object? value) => switch (value) {
  'INVALID_PAYLOAD' => SignalingErrorCode.invalidPayload,
  'NOT_JOINED' => SignalingErrorCode.notJoined,
  'UNAUTHORIZED' => SignalingErrorCode.unauthorized,
  'UNAVAILABLE' => SignalingErrorCode.unavailable,
  _ => SignalingErrorCode.unknown,
};

// ---------------------------------------------------------------- incoming

/// Reads a relayed `webrtc:offer`:
///
/// ```json
/// { "remoteSessionId": "...", "from": "TECHNICIAN", "sdp": "v=0..." }
/// ```
///
/// The relayed shape carries `from`, which the sender's does not: the backend
/// adds it and forwards only the fields it validated, so nothing the peer wrote
/// rides along.
OfferReceived? parseWebRtcOfferPayload(Object? payload) {
  final description = _readSessionDescription(payload);
  if (description == null) return null;
  return OfferReceived(
    offer: WebRtcOffer(
      remoteSessionId: description.remoteSessionId,
      sdp: description.sdp,
    ),
    from: description.from,
  );
}

/// Reads a relayed `webrtc:answer`. Same shape as an offer.
AnswerReceived? parseWebRtcAnswerPayload(Object? payload) {
  final description = _readSessionDescription(payload);
  if (description == null) return null;
  return AnswerReceived(
    answer: WebRtcAnswer(
      remoteSessionId: description.remoteSessionId,
      sdp: description.sdp,
    ),
    from: description.from,
  );
}

/// Reads a relayed `webrtc:ice-candidate`:
///
/// ```json
/// {
///   "remoteSessionId": "...", "from": "TECHNICIAN",
///   "candidate": "candidate:842163049 1 udp ...",
///   "sdpMid": "0", "sdpMLineIndex": 0
/// }
/// ```
///
/// The optional fields are normalised to `null` by the backend on the way out,
/// so both keys always arrive. An empty `candidate` is accepted — it is the
/// end-of-candidates signal, not a malformed payload — while an `sdpMid` or
/// `sdpMLineIndex` of an unexpected *type* is refused: a candidate this client
/// cannot read must not be half-applied to a peer connection later.
IceCandidateReceived? parseWebRtcIceCandidatePayload(Object? payload) {
  if (payload is! Map) return null;

  final remoteSessionId = payload['remoteSessionId'];
  if (remoteSessionId is! String || remoteSessionId.isEmpty) return null;

  final candidate = payload['candidate'];
  if (candidate is! String) return null;

  final sdpMid = payload['sdpMid'];
  if (sdpMid != null && sdpMid is! String) return null;

  final sdpMLineIndex = _readSdpMLineIndex(payload['sdpMLineIndex']);
  if (sdpMLineIndex == _unreadableIndex) return null;

  final from = _readOrigin(payload['from']);
  if (from == null) return null;

  return IceCandidateReceived(
    candidate: WebRtcIceCandidate(
      remoteSessionId: remoteSessionId,
      candidate: candidate,
      sdpMid: sdpMid as String?,
      sdpMLineIndex: sdpMLineIndex,
    ),
    from: from,
  );
}

/// Sentinel telling "absent, which is valid" apart from "present but not a
/// number, which is not". `null` alone could not say both, and the contract's
/// own range starts at 0, so no real index can collide with it.
const int _unreadableIndex = -1;

int? _readSdpMLineIndex(Object? value) {
  if (value == null) return null;
  // JSON has a single number type; a transport may hand back either Dart one.
  if (value is int) return value;
  if (value is double && value == value.roundToDouble()) return value.toInt();
  return _unreadableIndex;
}

/// `from` is added by the backend and is part of the documented relayed shape,
/// so a payload without it is not the event this client knows about. Its
/// *value* is read leniently: a participant kind added later must not void an
/// otherwise valid SDP, since what authorises a message is the session it
/// belongs to and never who claims to have sent it.
SignalingOrigin? _readOrigin(Object? value) => switch (value) {
  'DEVICE' => SignalingOrigin.device,
  'TECHNICIAN' => SignalingOrigin.technician,
  String() => SignalingOrigin.unknown,
  _ => null,
};

class _SessionDescription {
  const _SessionDescription({
    required this.remoteSessionId,
    required this.sdp,
    required this.from,
  });

  final String remoteSessionId;
  final String sdp;
  final SignalingOrigin from;
}

_SessionDescription? _readSessionDescription(Object? payload) {
  if (payload is! Map) return null;

  final remoteSessionId = payload['remoteSessionId'];
  if (remoteSessionId is! String || remoteSessionId.isEmpty) return null;

  final sdp = payload['sdp'];
  // Shape only: the maximum is the backend's to enforce, and it already did.
  // An empty SDP is refused because the contract's minimum is 1 and because
  // nothing downstream could do anything with it.
  if (sdp is! String || sdp.isEmpty) return null;

  final from = _readOrigin(payload['from']);
  if (from == null) return null;

  return _SessionDescription(
    remoteSessionId: remoteSessionId,
    sdp: sdp,
    from: from,
  );
}
