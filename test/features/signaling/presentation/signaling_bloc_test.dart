import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/signaling/domain/entities/join_remote_session_result.dart';
import 'package:remote_control_device/features/signaling/domain/entities/remote_signaling_message.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_error_code.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_relay_result.dart';
import 'package:remote_control_device/features/signaling/presentation/bloc/signaling/signaling_bloc.dart';

import '../../../fakes/realtime_fakes.dart';
import '../../../fakes/remote_session_fakes.dart';
import '../../../fakes/signaling_fakes.dart';

/// What the bloc alone is responsible for: the join state machine, the gate in
/// front of every outgoing message, and the session filter in front of every
/// incoming one.
///
/// When the join is *due* is not decided here — that is the coordinator's, and
/// it is tested in `test/app/signaling_coordinator_test.dart`.
void main() {
  late FakeDeviceRealtimeClient client;
  late SignalingBloc bloc;

  setUp(() {
    client = FakeDeviceRealtimeClient();
    bloc = SignalingBloc(client: client);
  });

  tearDown(() async {
    await bloc.close();
    await client.dispose();
  });

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> join([String id = testRemoteSessionId]) async {
    bloc.add(SignalingJoinRequested(id));
    await settle();
  }

  group('joining', () {
    test('a join that is accepted leaves the client able to relay', () async {
      await join();

      expect(client.joinedSessionIds, [testRemoteSessionId]);
      expect(bloc.state, const SignalingJoined(testRemoteSessionId));
      expect(bloc.joinedRemoteSessionId, testRemoteSessionId);
    });

    test('the state says joining while the ACK is outstanding', () async {
      final gate = Completer<void>();
      client.joinGate = gate;

      bloc.add(const SignalingJoinRequested(testRemoteSessionId));
      await settle();
      expect(bloc.state, const SignalingJoining(testRemoteSessionId));
      // A room membership is not claimed on the strength of having asked.
      expect(bloc.joinedRemoteSessionId, isNull);

      gate.complete();
      await settle();
      expect(bloc.state, const SignalingJoined(testRemoteSessionId));
    });

    test('repeating the same announcement does not join twice', () async {
      await join();
      await join();
      await join();

      // The session is re-read on every reconnection, on
      // remote-session:created and on ACCEPTED; none of that is a new join.
      expect(client.joinedSessionIds, [testRemoteSessionId]);
    });

    test('announcements arriving while one join is in flight do not stack',
        () async {
      final gate = Completer<void>();
      client.joinGate = gate;

      bloc.add(const SignalingJoinRequested(testRemoteSessionId));
      bloc.add(const SignalingJoinRequested(testRemoteSessionId));
      await settle();
      bloc.add(const SignalingJoinRequested(testRemoteSessionId));
      await settle();

      expect(client.joinedSessionIds, [testRemoteSessionId]);
      gate.complete();
      await settle();
      expect(bloc.state, const SignalingJoined(testRemoteSessionId));
    });

    test('a different session replaces the old membership', () async {
      await join();
      await join(testOtherRemoteSessionId);

      expect(client.joinedSessionIds, [
        testRemoteSessionId,
        testOtherRemoteSessionId,
      ]);
      expect(bloc.state, const SignalingJoined(testOtherRemoteSessionId));
    });

    test('a late ACK for an abandoned join is discarded', () async {
      final gate = Completer<void>();
      client.joinGate = gate;
      bloc.add(const SignalingJoinRequested(testRemoteSessionId));
      await settle();

      // The socket dies before the answer comes back.
      bloc.add(const SignalingConnectionLost());
      await settle();
      expect(bloc.state, const SignalingIdle());

      gate.complete();
      await settle();
      // Answering a question nobody is asking any more must not resurrect a
      // join that is already gone with its socket.
      expect(bloc.state, const SignalingIdle());
    });
  });

  group('losing the join', () {
    test('a lost connection is not joined any more', () async {
      await join();

      bloc.add(const SignalingConnectionLost());
      await settle();

      expect(bloc.state, const SignalingIdle());
      expect(bloc.joinedRemoteSessionId, isNull);
    });

    test('a reconnection joins again rather than assuming the old room',
        () async {
      await join();
      bloc.add(const SignalingConnectionLost());
      await settle();

      await join();

      // "Joined sessions do not survive. A new socket has no session attached."
      expect(client.joinedSessionIds, [
        testRemoteSessionId,
        testRemoteSessionId,
      ]);
      expect(bloc.state, const SignalingJoined(testRemoteSessionId));
    });

    test('a session that ended clears the membership', () async {
      await join();

      bloc.add(const SignalingSessionEnded());
      await settle();

      expect(bloc.state, const SignalingIdle());
    });

    test('nothing is claimed to have changed when it has not', () async {
      final states = <SignalingState>[];
      final subscription = bloc.stream.listen(states.add);

      bloc.add(const SignalingConnectionLost());
      bloc.add(const SignalingSessionEnded());
      await settle();

      expect(states, isEmpty);
      await subscription.cancel();
    });
  });

  group('a refused join', () {
    test('UNAUTHORIZED does not retry and does not touch anything else',
        () async {
      client.joinResult = const RemoteSessionJoinRefused(
        SignalingErrorCode.unauthorized,
      );

      await join();
      await join();
      await join();

      expect(client.joinedSessionIds, [testRemoteSessionId]);
      expect(
        bloc.state,
        const SignalingUnavailable(
          testRemoteSessionId,
          error: SignalingErrorCode.unauthorized,
        ),
      );
    });

    test('INVALID_PAYLOAD is a contract error, so it is never retried',
        () async {
      client.joinResult = const RemoteSessionJoinRefused(
        SignalingErrorCode.invalidPayload,
      );

      await join();
      await join();

      expect(client.joinedSessionIds, hasLength(1));
      expect(
        bloc.state,
        const SignalingUnavailable(
          testRemoteSessionId,
          error: SignalingErrorCode.invalidPayload,
        ),
      );
    });

    test('a missing ACK is recorded without an error code', () async {
      client.joinResult = const RemoteSessionJoinUnanswered();

      await join();

      // "No verdict" and "refused" must not look the same.
      expect(bloc.state, const SignalingUnavailable(testRemoteSessionId));
      expect((bloc.state as SignalingUnavailable).error, isNull);
    });

    test('a new socket is a real change, so it is tried again', () async {
      client.joinQueue.add(
        const RemoteSessionJoinRefused(SignalingErrorCode.unauthorized),
      );
      await join();
      expect(bloc.state, isA<SignalingUnavailable>());

      bloc.add(const SignalingConnectionLost());
      await settle();
      await join();

      expect(client.joinedSessionIds, hasLength(2));
      expect(bloc.state, const SignalingJoined(testRemoteSessionId));
    });

    test('a different session is a real change too', () async {
      client.joinQueue.add(
        const RemoteSessionJoinRefused(SignalingErrorCode.unauthorized),
      );
      await join();

      await join(testOtherRemoteSessionId);

      expect(bloc.state, const SignalingJoined(testOtherRemoteSessionId));
    });

    test('an explicit retry is the deliberate way out', () async {
      client.joinQueue.add(
        const RemoteSessionJoinRefused(SignalingErrorCode.unavailable),
      );
      await join();

      bloc.add(const SignalingRetryRequested());
      await settle();

      expect(client.joinedSessionIds, hasLength(2));
      expect(bloc.state, const SignalingJoined(testRemoteSessionId));
    });

    test('a retry with nothing to retry does nothing', () async {
      bloc.add(const SignalingRetryRequested());
      await settle();

      expect(client.joinedSessionIds, isEmpty);
      expect(bloc.state, const SignalingIdle());
    });
  });

  group('sending', () {
    test('an offer is relayed once joined', () async {
      await join();

      final result = await bloc.sendOffer(testOffer);

      expect(client.sentOffers, [testOffer]);
      expect(result, const SignalingRelayDelivered(testRemoteSessionId));
    });

    test('an answer is relayed once joined', () async {
      await join();

      final result = await bloc.sendAnswer(testAnswer);

      expect(client.sentAnswers, [testAnswer]);
      expect(result, const SignalingRelayDelivered(testRemoteSessionId));
    });

    test('an ICE candidate is relayed once joined', () async {
      await join();

      final result = await bloc.sendIceCandidate(testCandidate);

      expect(client.sentIceCandidates, [testCandidate]);
      expect(result, const SignalingRelayDelivered(testRemoteSessionId));
    });

    test('nothing is emitted before the join', () async {
      final offer = await bloc.sendOffer(testOffer);
      final answer = await bloc.sendAnswer(testAnswer);
      final candidate = await bloc.sendIceCandidate(testCandidate);

      // remote-session:join is mandatory before any webrtc:*, and the client
      // enforces it instead of spending a round trip learning it.
      expect(client.relayCount, 0);
      const refused = SignalingRelayNotSent(SignalingNotSentReason.notJoined);
      expect(offer, refused);
      expect(answer, refused);
      expect(candidate, refused);
    });

    test('nothing is emitted for a session other than the joined one',
        () async {
      await join(testOtherRemoteSessionId);

      final result = await bloc.sendOffer(testOffer);

      expect(client.relayCount, 0);
      expect(
        result,
        const SignalingRelayNotSent(SignalingNotSentReason.notJoined),
      );
    });

    test('nothing is emitted once the connection is gone', () async {
      await join();
      bloc.add(const SignalingConnectionLost());
      await settle();

      final result = await bloc.sendOffer(testOffer);

      expect(client.relayCount, 0);
      expect(
        result,
        const SignalingRelayNotSent(SignalingNotSentReason.notJoined),
      );
    });

    test('a refusal is reported with its documented code, unaltered', () async {
      await join();
      client.relayResult = const SignalingRelayRefused(
        SignalingErrorCode.unavailable,
      );

      final result = await bloc.sendOffer(testOffer);
      await settle();

      expect(
        result,
        const SignalingRelayRefused(SignalingErrorCode.unavailable),
      );
      // A transient server-side condition says nothing about the join, so it
      // touches nothing — and the message is not resent on its own.
      expect(bloc.state, const SignalingJoined(testRemoteSessionId));
      expect(client.sentOffers, hasLength(1));
    });

    test('UNAUTHORIZED stops signaling for the session instead of retrying it',
        () async {
      await join();
      client.relayResult = const SignalingRelayRefused(
        SignalingErrorCode.unauthorized,
      );

      final result = await bloc.sendOffer(testOffer);
      await settle();

      expect(
        result,
        const SignalingRelayRefused(SignalingErrorCode.unauthorized),
      );
      // Every relayed message is re-validated, so this says the session is
      // gone, CLOSED or not this device's — re-joining would be refused too.
      expect(
        bloc.state,
        const SignalingUnavailable(
          testRemoteSessionId,
          error: SignalingErrorCode.unauthorized,
        ),
      );
      expect(client.joinedSessionIds, hasLength(1));
      // And nothing further may be emitted for it.
      expect(
        await bloc.sendOffer(testOffer),
        const SignalingRelayNotSent(SignalingNotSentReason.notJoined),
      );
    });

    test('delivered means handed over, and is reported as nothing more',
        () async {
      await join();

      final result = await bloc.sendOffer(testOffer);

      expect(result, isA<SignalingRelayDelivered>());
      // Deliberately no "the technician has the offer" state anywhere: if the
      // other end has not joined, the room is empty and the message is dropped.
      expect(bloc.state, const SignalingJoined(testRemoteSessionId));
    });

    test('NOT_JOINED sends the client back through the join, not through a '
        'resend', () async {
      await join();
      client.relayResult = const SignalingRelayRefused(
        SignalingErrorCode.notJoined,
      );

      final result = await bloc.sendOffer(testOffer);
      await settle();

      expect(
        result,
        const SignalingRelayRefused(SignalingErrorCode.notJoined),
      );
      // Joined again...
      expect(client.joinedSessionIds, [
        testRemoteSessionId,
        testRemoteSessionId,
      ]);
      expect(bloc.state, const SignalingJoined(testRemoteSessionId));
      // ...and the refused offer was not put on the wire a second time.
      expect(client.sentOffers, hasLength(1));
    });
  });

  group('incoming', () {
    test('an offer for the joined session is handed on, typed', () async {
      await join();
      final received = <RemoteSignalingMessage>[];
      final subscription = bloc.incoming.listen(received.add);

      await client.deliver(offerReceived());

      expect(received, [offerReceived()]);
      expect(received.single, isA<OfferReceived>());
      await subscription.cancel();
    });

    test('an answer is handed on, typed', () async {
      await join();
      final received = <RemoteSignalingMessage>[];
      final subscription = bloc.incoming.listen(received.add);

      await client.deliver(answerReceived());

      expect(received.single, isA<AnswerReceived>());
      expect((received.single as AnswerReceived).answer.sdp, testAnswerSdp);
      await subscription.cancel();
    });

    test('an ICE candidate is handed on, typed', () async {
      await join();
      final received = <RemoteSignalingMessage>[];
      final subscription = bloc.incoming.listen(received.add);

      await client.deliver(iceCandidateReceived());

      expect(received.single, isA<IceCandidateReceived>());
      final candidate = (received.single as IceCandidateReceived).candidate;
      expect(candidate.candidate, testIceCandidate);
      expect(candidate.sdpMid, '0');
      expect(candidate.sdpMLineIndex, 0);
      await subscription.cancel();
    });

    test('a message naming another session is dropped, never followed',
        () async {
      await join();
      final received = <RemoteSignalingMessage>[];
      final subscription = bloc.incoming.listen(received.add);

      await client.deliver(
        offerReceived(remoteSessionId: testOtherRemoteSessionId),
      );

      expect(received, isEmpty);
      // And above all the client did not switch to the session it named.
      expect(bloc.state, const SignalingJoined(testRemoteSessionId));
      await subscription.cancel();
    });

    test('a message arriving before the join is dropped', () async {
      final received = <RemoteSignalingMessage>[];
      final subscription = bloc.incoming.listen(received.add);

      await client.deliver(offerReceived());

      expect(received, isEmpty);
      await subscription.cancel();
    });

    test('a message arriving after the connection dropped is dropped too',
        () async {
      await join();
      final received = <RemoteSignalingMessage>[];
      final subscription = bloc.incoming.listen(received.add);

      bloc.add(const SignalingConnectionLost());
      await settle();
      await client.deliver(offerReceived());

      expect(received, isEmpty);
      await subscription.cancel();
    });
  });

  group('ownership', () {
    test('closing the bloc leaves the socket alone', () async {
      await bloc.close();

      // The socket belongs to DeviceRealtimeBloc; this one only ever had a
      // second view of it, and must not take the connection down with it.
      expect(client.disposeCount, 0);
      expect(client.disconnectCount, 0);
    });
  });
}
