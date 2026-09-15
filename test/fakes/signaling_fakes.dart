import 'package:remote_control_device/features/signaling/domain/entities/remote_signaling_message.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_origin.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_answer.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_ice_candidate.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_offer.dart';

import 'remote_session_fakes.dart';

/// Fixtures transcribed from the payloads printed in `docs/backend/REALTIME.md`
/// so a contract test reads against the document rather than against the code.

/// The offer SDP the contract prints, abbreviated exactly as it is there.
const String testSdp = 'v=0\r\no=- 46117 2 IN IP4 127.0.0.1\r\n';

/// A second, different SDP, so an answer can never be mistaken for an offer.
const String testAnswerSdp = 'v=0\r\no=- 90210 2 IN IP4 127.0.0.1\r\n';

/// The candidate line the contract prints.
const String testIceCandidate =
    'candidate:842163049 1 udp 1677729535 192.0.2.10 54321 typ srflx';

const WebRtcOffer testOffer = WebRtcOffer(
  remoteSessionId: testRemoteSessionId,
  sdp: testSdp,
);

const WebRtcAnswer testAnswer = WebRtcAnswer(
  remoteSessionId: testRemoteSessionId,
  sdp: testAnswerSdp,
);

const WebRtcIceCandidate testCandidate = WebRtcIceCandidate(
  remoteSessionId: testRemoteSessionId,
  candidate: testIceCandidate,
  sdpMid: '0',
  sdpMLineIndex: 0,
);

/// The `webrtc:offer` payload **as delivered to the peer** — the one carrying
/// `from`, which the sender's copy never has.
Map<String, dynamic> relayedOfferPayload({
  String remoteSessionId = testRemoteSessionId,
}) => <String, dynamic>{
  'remoteSessionId': remoteSessionId,
  'from': 'TECHNICIAN',
  'sdp': testSdp,
};

/// The `webrtc:answer` payload as delivered to the peer.
Map<String, dynamic> relayedAnswerPayload({
  String remoteSessionId = testRemoteSessionId,
}) => <String, dynamic>{
  'remoteSessionId': remoteSessionId,
  'from': 'TECHNICIAN',
  'sdp': testAnswerSdp,
};

/// The `webrtc:ice-candidate` payload as delivered to the peer.
Map<String, dynamic> relayedIcePayload({
  String remoteSessionId = testRemoteSessionId,
}) => <String, dynamic>{
  'remoteSessionId': remoteSessionId,
  'from': 'TECHNICIAN',
  'candidate': testIceCandidate,
  'sdpMid': '0',
  'sdpMLineIndex': 0,
};

/// A parsed offer, as the transport would hand it to `SignalingBloc`.
///
/// [sdp] is a parameter because a second, different offer is what a reloaded
/// browser sends, and telling that from a repeat of the first one is a
/// decision the WebRTC layer has to take.
OfferReceived offerReceived({
  String remoteSessionId = testRemoteSessionId,
  String sdp = testSdp,
}) => OfferReceived(
  offer: WebRtcOffer(remoteSessionId: remoteSessionId, sdp: sdp),
  from: SignalingOrigin.technician,
);

/// A parsed answer.
AnswerReceived answerReceived({String remoteSessionId = testRemoteSessionId}) =>
    AnswerReceived(
      answer: WebRtcAnswer(remoteSessionId: remoteSessionId, sdp: testAnswerSdp),
      from: SignalingOrigin.technician,
    );

/// A parsed ICE candidate.
IceCandidateReceived iceCandidateReceived({
  String remoteSessionId = testRemoteSessionId,
}) => IceCandidateReceived(
  candidate: WebRtcIceCandidate(
    remoteSessionId: remoteSessionId,
    candidate: testIceCandidate,
    sdpMid: '0',
    sdpMLineIndex: 0,
  ),
  from: SignalingOrigin.technician,
);
