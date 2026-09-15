import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/signaling/data/signaling_events.dart';
import 'package:remote_control_device/features/signaling/data/signaling_payloads.dart';
import 'package:remote_control_device/features/signaling/domain/entities/join_remote_session_result.dart';
import 'package:remote_control_device/features/signaling/domain/entities/remote_session_peer_readiness.dart';
import 'package:remote_control_device/features/signaling/domain/entities/remote_signaling_message.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_error_code.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_origin.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_relay_result.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_answer.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_ice_candidate.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_offer.dart';

import '../../../fakes/remote_session_fakes.dart';
import '../../../fakes/signaling_fakes.dart';

/// Checks the signaling half of `docs/backend/REALTIME.md` field by field:
/// the four event names, the exact outgoing payloads, both ACK shapes, the
/// stable error codes, and the nullability the contract actually documents.
///
/// Written against the document rather than against the implementation — the
/// fixtures are the payloads printed in it — so that a change on either side
/// which the other has not followed fails here.
void main() {
  group('event names', () {
    test('are spelled exactly as the contract does', () {
      expect(remoteSessionJoinEvent, 'remote-session:join');
      expect(webRtcOfferEvent, 'webrtc:offer');
      expect(webRtcAnswerEvent, 'webrtc:answer');
      expect(webRtcIceCandidateEvent, 'webrtc:ice-candidate');
      expect(remoteSessionPeerJoinedEvent, 'remote-session:peer-joined');
    });
  });

  group('remote-session:peer-joined', () {
    test('is read as the documented payload', () {
      expect(
        parseRemoteSessionPeerJoinedPayload({
          'remoteSessionId': testRemoteSessionId,
        }),
        const RemoteSessionPeerReady(testRemoteSessionId),
      );
    });

    test('a session id is all it needs, and all it is read for', () {
      // Later fields must not void a notice this build can already act on —
      // and the only thing it acts on is comparing the id with the session it
      // is joined to.
      expect(
        parseRemoteSessionPeerJoinedPayload({
          'remoteSessionId': testRemoteSessionId,
          'somethingAddedLater': 42,
        }),
        const RemoteSessionPeerReady(testRemoteSessionId),
      );
    });

    test('malformed payloads produce no readiness at all', () {
      expect(parseRemoteSessionPeerJoinedPayload(null), isNull);
      expect(parseRemoteSessionPeerJoinedPayload(const []), isNull);
      expect(parseRemoteSessionPeerJoinedPayload('peer'), isNull);
      expect(
        parseRemoteSessionPeerJoinedPayload(const <String, Object?>{}),
        isNull,
      );
      expect(
        parseRemoteSessionPeerJoinedPayload({'remoteSessionId': ''}),
        isNull,
      );
      expect(
        parseRemoteSessionPeerJoinedPayload({'remoteSessionId': 42}),
        isNull,
      );
    });
  });

  group('documented limits', () {
    test('match the contract tables', () {
      expect(minSdpLength, 1);
      expect(maxSdpLength, 32768);
      expect(maxIceCandidateLength, 1024);
      expect(maxSdpMidLength, 64);
      expect(minSdpMLineIndex, 0);
      expect(maxSdpMLineIndex, 255);
    });
  });

  group('remote-session:join payload', () {
    test('carries remoteSessionId and nothing else', () {
      final payload = buildRemoteSessionJoinPayload(testRemoteSessionId);

      // "This is the only accepted property... Any extra property makes the
      // payload invalid." In particular the participant is never sent.
      expect(payload, {'remoteSessionId': testRemoteSessionId});
      expect(payload!.keys, hasLength(1));
    });

    test('refuses an id that is not a UUID', () {
      expect(buildRemoteSessionJoinPayload(''), isNull);
      expect(buildRemoteSessionJoinPayload('not-a-uuid'), isNull);
      expect(buildRemoteSessionJoinPayload('$testRemoteSessionId '), isNull);
    });
  });

  group('JoinRemoteSessionAck', () {
    test('the accepted shape is read as documented', () {
      // Readiness travels with the acceptance: the ACK says whether the
      // technician's socket was already in the same session room.
      expect(
        parseJoinRemoteSessionAck({
          'joined': true,
          'remoteSessionId': testRemoteSessionId,
          'peerJoined': true,
        }),
        const RemoteSessionJoined(testRemoteSessionId, peerJoined: true),
      );
      expect(
        parseJoinRemoteSessionAck({
          'joined': true,
          'remoteSessionId': testRemoteSessionId,
          'peerJoined': false,
        }),
        const RemoteSessionJoined(testRemoteSessionId, peerJoined: false),
      );
    });

    test('a join without a readable peerJoined is not an acceptance', () {
      // Never defaulted. A `false` invented here would report "the technician
      // is not there" as though the backend had said so, and a `true` would
      // claim the opposite; both are half an answer presented as a whole one.
      expect(
        parseJoinRemoteSessionAck({
          'joined': true,
          'remoteSessionId': testRemoteSessionId,
        }),
        const RemoteSessionJoinUnanswered(),
      );
      expect(
        parseJoinRemoteSessionAck({
          'joined': true,
          'remoteSessionId': testRemoteSessionId,
          'peerJoined': 'true',
        }),
        const RemoteSessionJoinUnanswered(),
      );
      expect(
        parseJoinRemoteSessionAck({
          'joined': true,
          'remoteSessionId': testRemoteSessionId,
          'peerJoined': null,
        }),
        const RemoteSessionJoinUnanswered(),
      );
    });

    test('the rejected shape is read as documented', () {
      expect(
        parseJoinRemoteSessionAck({
          'joined': false,
          'error': 'UNAUTHORIZED',
        }),
        const RemoteSessionJoinRefused(SignalingErrorCode.unauthorized),
      );
      expect(
        parseJoinRemoteSessionAck({
          'joined': false,
          'error': 'INVALID_PAYLOAD',
        }),
        const RemoteSessionJoinRefused(SignalingErrorCode.invalidPayload),
      );
    });

    test('a malformed ACK is the absence of a verdict, not one', () {
      // Neither "joined" nor "refused": a client that read either from these
      // would be inventing an answer the backend did not give.
      expect(
        parseJoinRemoteSessionAck(null),
        const RemoteSessionJoinUnanswered(),
      );
      expect(
        parseJoinRemoteSessionAck('joined'),
        const RemoteSessionJoinUnanswered(),
      );
      expect(
        parseJoinRemoteSessionAck(const []),
        const RemoteSessionJoinUnanswered(),
      );
      expect(
        parseJoinRemoteSessionAck(const <String, Object?>{}),
        const RemoteSessionJoinUnanswered(),
      );
      expect(
        parseJoinRemoteSessionAck({'joined': 'true'}),
        const RemoteSessionJoinUnanswered(),
      );
      expect(
        parseJoinRemoteSessionAck({'joined': true}),
        const RemoteSessionJoinUnanswered(),
      );
      expect(
        parseJoinRemoteSessionAck({'joined': true, 'peerJoined': true}),
        const RemoteSessionJoinUnanswered(),
      );
    });
  });

  group('webrtc:offer payload', () {
    test('is exactly remoteSessionId and sdp', () {
      final payload = buildWebRtcOfferPayload(
        const WebRtcOffer(remoteSessionId: testRemoteSessionId, sdp: testSdp),
      );

      expect(payload, {
        'remoteSessionId': testRemoteSessionId,
        'sdp': testSdp,
      });
      expect(payload!.keys, hasLength(2));
      // `from` is added by the server; a client that sent one would be sending
      // an unknown property and earning an INVALID_PAYLOAD.
      expect(payload.containsKey('from'), isFalse);
    });

    test('respects the documented 1-32768 range', () {
      WebRtcOffer offerOf(String sdp) =>
          WebRtcOffer(remoteSessionId: testRemoteSessionId, sdp: sdp);

      expect(buildWebRtcOfferPayload(offerOf('')), isNull);
      expect(buildWebRtcOfferPayload(offerOf('v')), isNotNull);
      expect(
        buildWebRtcOfferPayload(offerOf('v' * maxSdpLength)),
        isNotNull,
      );
      expect(
        buildWebRtcOfferPayload(offerOf('v' * (maxSdpLength + 1))),
        isNull,
      );
    });

    test('refuses a session id that is not a UUID', () {
      expect(
        buildWebRtcOfferPayload(
          const WebRtcOffer(remoteSessionId: 'nope', sdp: testSdp),
        ),
        isNull,
      );
    });
  });

  group('webrtc:answer payload', () {
    test('is identical in shape to an offer', () {
      final answer = buildWebRtcAnswerPayload(
        const WebRtcAnswer(remoteSessionId: testRemoteSessionId, sdp: testSdp),
      );
      final offer = buildWebRtcOfferPayload(
        const WebRtcOffer(remoteSessionId: testRemoteSessionId, sdp: testSdp),
      );

      // "Identical to webrtc:offer in payload, constraints, relayed shape and
      // ACK. Only the event name differs."
      expect(answer, offer);
    });

    test('respects the same range', () {
      expect(
        buildWebRtcAnswerPayload(
          const WebRtcAnswer(remoteSessionId: testRemoteSessionId, sdp: ''),
        ),
        isNull,
      );
      expect(
        buildWebRtcAnswerPayload(
          WebRtcAnswer(
            remoteSessionId: testRemoteSessionId,
            sdp: 'v' * (maxSdpLength + 1),
          ),
        ),
        isNull,
      );
    });
  });

  group('webrtc:ice-candidate payload', () {
    test('carries all four documented fields', () {
      final payload = buildWebRtcIceCandidatePayload(
        const WebRtcIceCandidate(
          remoteSessionId: testRemoteSessionId,
          candidate: testIceCandidate,
          sdpMid: '0',
          sdpMLineIndex: 0,
        ),
      );

      expect(payload, {
        'remoteSessionId': testRemoteSessionId,
        'candidate': testIceCandidate,
        'sdpMid': '0',
        'sdpMLineIndex': 0,
      });
    });

    test('writes the optional fields as explicit nulls when absent', () {
      // The contract allows both forms; always writing both keys keeps every
      // candidate leaving this client identical in shape.
      final payload = buildWebRtcIceCandidatePayload(
        const WebRtcIceCandidate(
          remoteSessionId: testRemoteSessionId,
          candidate: testIceCandidate,
        ),
      );

      expect(payload, {
        'remoteSessionId': testRemoteSessionId,
        'candidate': testIceCandidate,
        'sdpMid': null,
        'sdpMLineIndex': null,
      });
    });

    test('allows the empty candidate, which signals end-of-candidates', () {
      expect(
        buildWebRtcIceCandidatePayload(
          const WebRtcIceCandidate(
            remoteSessionId: testRemoteSessionId,
            candidate: '',
          ),
        ),
        isNotNull,
      );
    });

    test('respects every documented bound', () {
      WebRtcIceCandidate candidateWith({
        String candidate = testIceCandidate,
        String? sdpMid,
        int? sdpMLineIndex,
      }) => WebRtcIceCandidate(
        remoteSessionId: testRemoteSessionId,
        candidate: candidate,
        sdpMid: sdpMid,
        sdpMLineIndex: sdpMLineIndex,
      );

      expect(
        buildWebRtcIceCandidatePayload(
          candidateWith(candidate: 'c' * maxIceCandidateLength),
        ),
        isNotNull,
      );
      expect(
        buildWebRtcIceCandidatePayload(
          candidateWith(candidate: 'c' * (maxIceCandidateLength + 1)),
        ),
        isNull,
      );
      expect(
        buildWebRtcIceCandidatePayload(
          candidateWith(sdpMid: 'm' * maxSdpMidLength),
        ),
        isNotNull,
      );
      expect(
        buildWebRtcIceCandidatePayload(
          candidateWith(sdpMid: 'm' * (maxSdpMidLength + 1)),
        ),
        isNull,
      );
      expect(
        buildWebRtcIceCandidatePayload(candidateWith(sdpMLineIndex: 0)),
        isNotNull,
      );
      expect(
        buildWebRtcIceCandidatePayload(candidateWith(sdpMLineIndex: 255)),
        isNotNull,
      );
      expect(
        buildWebRtcIceCandidatePayload(candidateWith(sdpMLineIndex: -1)),
        isNull,
      );
      expect(
        buildWebRtcIceCandidatePayload(candidateWith(sdpMLineIndex: 256)),
        isNull,
      );
    });
  });

  group('SignalingRelayAck', () {
    test('the accepted shape is read as documented', () {
      expect(
        parseSignalingRelayAck({
          'delivered': true,
          'remoteSessionId': testRemoteSessionId,
        }),
        const SignalingRelayDelivered(testRemoteSessionId),
      );
    });

    test('every documented error code is read', () {
      SignalingRelayResult refusedWith(String code) =>
          parseSignalingRelayAck({'delivered': false, 'error': code});

      expect(
        refusedWith('INVALID_PAYLOAD'),
        const SignalingRelayRefused(SignalingErrorCode.invalidPayload),
      );
      expect(
        refusedWith('NOT_JOINED'),
        const SignalingRelayRefused(SignalingErrorCode.notJoined),
      );
      expect(
        refusedWith('UNAUTHORIZED'),
        const SignalingRelayRefused(SignalingErrorCode.unauthorized),
      );
      expect(
        refusedWith('UNAVAILABLE'),
        const SignalingRelayRefused(SignalingErrorCode.unavailable),
      );
    });

    test('a code this build has never seen is admitted as unknown', () {
      // Never guessed at, and never crashed on: the codes are the stable part
      // of the contract, but the contract may grow.
      expect(
        parseSignalingRelayAck({
          'delivered': false,
          'error': 'SOMETHING_ADDED_LATER',
        }),
        const SignalingRelayRefused(SignalingErrorCode.unknown),
      );
      expect(
        parseSignalingRelayAck({'delivered': false}),
        const SignalingRelayRefused(SignalingErrorCode.unknown),
      );
    });

    test('a malformed ACK is unanswered, not delivered', () {
      expect(parseSignalingRelayAck(null), const SignalingRelayUnanswered());
      expect(
        parseSignalingRelayAck('delivered'),
        const SignalingRelayUnanswered(),
      );
      expect(
        parseSignalingRelayAck({'delivered': true}),
        const SignalingRelayUnanswered(),
      );
      expect(
        parseSignalingRelayAck(const <String, Object?>{}),
        const SignalingRelayUnanswered(),
      );
    });

    test('never branches on a human-readable string', () {
      // The contract: "clients must branch on error, never on a
      // human-readable string".
      expect(
        parseSignalingRelayAck({
          'delivered': false,
          'error': 'NOT_JOINED',
          'message': 'You have not joined this remote session',
        }),
        const SignalingRelayRefused(SignalingErrorCode.notJoined),
      );
    });
  });

  group('incoming webrtc:offer', () {
    test('is read as the documented relayed shape', () {
      final message = parseWebRtcOfferPayload(relayedOfferPayload());

      expect(message, isA<OfferReceived>());
      expect(message!.remoteSessionId, testRemoteSessionId);
      expect(message.from, SignalingOrigin.technician);
      expect(message.offer.sdp, testSdp);
    });

    test('a DEVICE origin is read too, although /devices never sees one', () {
      final message = parseWebRtcOfferPayload(
        relayedOfferPayload()..['from'] = 'DEVICE',
      );
      expect(message!.from, SignalingOrigin.device);
    });

    test('an origin this build has never seen does not void the SDP', () {
      // What authorises a message is the session it belongs to, never who
      // claims to have sent it.
      final message = parseWebRtcOfferPayload(
        relayedOfferPayload()..['from'] = 'SOMETHING_NEW',
      );
      expect(message, isNotNull);
      expect(message!.from, SignalingOrigin.unknown);
    });

    test('malformed payloads are discarded instead of half-read', () {
      expect(parseWebRtcOfferPayload(null), isNull);
      expect(parseWebRtcOfferPayload('webrtc:offer'), isNull);
      expect(parseWebRtcOfferPayload(const []), isNull);
      expect(
        parseWebRtcOfferPayload(relayedOfferPayload()..remove('sdp')),
        isNull,
      );
      expect(
        parseWebRtcOfferPayload(relayedOfferPayload()..['sdp'] = ''),
        isNull,
      );
      expect(
        parseWebRtcOfferPayload(relayedOfferPayload()..['sdp'] = 42),
        isNull,
      );
      expect(
        parseWebRtcOfferPayload(
          relayedOfferPayload()..remove('remoteSessionId'),
        ),
        isNull,
      );
      expect(
        parseWebRtcOfferPayload(relayedOfferPayload()..remove('from')),
        isNull,
      );
    });

    test('an oversized incoming SDP is not second-guessed', () {
      // Size is the backend's to enforce and it already did. Re-imposing this
      // build's copy of the limit would make it reject what a later backend
      // legitimately allows.
      final message = parseWebRtcOfferPayload(
        relayedOfferPayload()..['sdp'] = 'v' * (maxSdpLength + 1),
      );
      expect(message, isNotNull);
    });
  });

  group('incoming webrtc:answer', () {
    test('is read as the documented relayed shape', () {
      final message = parseWebRtcAnswerPayload(relayedAnswerPayload());

      expect(message, isA<AnswerReceived>());
      expect(message!.remoteSessionId, testRemoteSessionId);
      expect(message.from, SignalingOrigin.technician);
      expect(message.answer.sdp, testAnswerSdp);
    });

    test('malformed payloads are discarded', () {
      expect(parseWebRtcAnswerPayload(null), isNull);
      expect(
        parseWebRtcAnswerPayload(relayedAnswerPayload()..remove('sdp')),
        isNull,
      );
      expect(
        parseWebRtcAnswerPayload(relayedAnswerPayload()..remove('from')),
        isNull,
      );
    });
  });

  group('incoming webrtc:ice-candidate', () {
    test('is read as the documented relayed shape', () {
      final message = parseWebRtcIceCandidatePayload(relayedIcePayload());

      expect(message, isA<IceCandidateReceived>());
      expect(message!.remoteSessionId, testRemoteSessionId);
      expect(message.from, SignalingOrigin.technician);
      expect(message.candidate.candidate, testIceCandidate);
      expect(message.candidate.sdpMid, '0');
      expect(message.candidate.sdpMLineIndex, 0);
    });

    test('the nulls the backend normalises to are read as nulls', () {
      // "Omitted optional fields are normalized to null on the way out, so the
      // receiver always gets both keys."
      final message = parseWebRtcIceCandidatePayload(
        relayedIcePayload()
          ..['sdpMid'] = null
          ..['sdpMLineIndex'] = null,
      );

      expect(message, isNotNull);
      expect(message!.candidate.sdpMid, isNull);
      expect(message.candidate.sdpMLineIndex, isNull);
    });

    test('the empty candidate is a valid end-of-candidates signal', () {
      final message = parseWebRtcIceCandidatePayload(
        relayedIcePayload()..['candidate'] = '',
      );

      expect(message, isNotNull);
      expect(message!.candidate.candidate, isEmpty);
    });

    test('an index arriving as a JSON double is read as an integer', () {
      final message = parseWebRtcIceCandidatePayload(
        relayedIcePayload()..['sdpMLineIndex'] = 1.0,
      );
      expect(message!.candidate.sdpMLineIndex, 1);
    });

    test('malformed payloads are discarded instead of half-read', () {
      expect(parseWebRtcIceCandidatePayload(null), isNull);
      expect(parseWebRtcIceCandidatePayload(const []), isNull);
      expect(
        parseWebRtcIceCandidatePayload(relayedIcePayload()..remove('candidate')),
        isNull,
      );
      expect(
        parseWebRtcIceCandidatePayload(relayedIcePayload()..['candidate'] = 42),
        isNull,
      );
      expect(
        parseWebRtcIceCandidatePayload(relayedIcePayload()..['sdpMid'] = 42),
        isNull,
      );
      expect(
        parseWebRtcIceCandidatePayload(
          relayedIcePayload()..['sdpMLineIndex'] = 'zero',
        ),
        isNull,
      );
      expect(
        parseWebRtcIceCandidatePayload(relayedIcePayload()..remove('from')),
        isNull,
      );
      expect(
        parseWebRtcIceCandidatePayload(
          relayedIcePayload()..['remoteSessionId'] = '',
        ),
        isNull,
      );
    });
  });

  group('logging safety', () {
    test('no signaling model can print an SDP or a candidate', () {
      // The contract says SDP and ICE are never written to the backend logs;
      // the same holds here, including through an accidental interpolation.
      const offer = WebRtcOffer(
        remoteSessionId: testRemoteSessionId,
        sdp: testSdp,
      );
      const answer = WebRtcAnswer(
        remoteSessionId: testRemoteSessionId,
        sdp: testAnswerSdp,
      );
      const candidate = WebRtcIceCandidate(
        remoteSessionId: testRemoteSessionId,
        candidate: testIceCandidate,
      );

      expect('$offer', isNot(contains(testSdp)));
      expect('$answer', isNot(contains(testAnswerSdp)));
      expect('$candidate', isNot(contains(testIceCandidate)));
      // The session id is an operational identifier and may be logged.
      expect('$offer', contains(testRemoteSessionId));
    });
  });
}
