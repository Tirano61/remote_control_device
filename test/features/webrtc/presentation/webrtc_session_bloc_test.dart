import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_error_code.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_relay_result.dart';
import 'package:remote_control_device/features/webrtc/domain/control_channel.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/peer_ice_candidate.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_message.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_session_description.dart';
import 'package:remote_control_device/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../../../fakes/remote_session_fakes.dart';
import '../../../fakes/signaling_fakes.dart';
import '../../../fakes/webrtc_fakes.dart';

/// The answering half of the negotiation, exercised without a native WebRTC
/// stack.
///
/// What is being checked here is everything that is a *decision*: when a peer
/// connection may be created at all, what order the SDP steps happen in, which
/// candidate may leave and when, which data channel is kept, and what survives
/// a socket that went away. The parts that are genuinely libwebrtc's — whether
/// two endpoints actually pair — are not testable here and are verified with a
/// browser and a tablet.
void main() {
  late FakeWebRtcPeerConnectionFactory factory;
  late FakeWebRtcSignalingGateway signaling;
  late WebRtcSessionBloc bloc;

  setUp(() {
    factory = FakeWebRtcPeerConnectionFactory();
    signaling = FakeWebRtcSignalingGateway();
    bloc = WebRtcSessionBloc(
      peerConnectionFactory: factory,
      signaling: signaling,
      iceConfiguration: const WebRtcIceConfiguration.none(),
    );
  });

  tearDown(() async => bloc.close());

  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Both preconditions in place: the socket is joined and the backend holds
  /// the session live. Nothing is negotiated by this — that is the point.
  Future<void> becomeReady({String id = testRemoteSessionId}) async {
    bloc.add(WebRtcSignalingAvailabilityChanged(id));
    bloc.add(WebRtcRemoteSessionChanged(id));
    await settle();
  }

  Future<void> receiveOffer({
    String remoteSessionId = testRemoteSessionId,
    String sdp = testSdp,
  }) async {
    bloc.add(
      WebRtcOfferReceived(offerFor(remoteSessionId: remoteSessionId, sdp: sdp)),
    );
    await settle();
  }

  /// A complete, successful negotiation up to `WebRtcConnecting`.
  Future<FakeWebRtcPeerConnection> negotiate() async {
    await becomeReady();
    await receiveOffer();
    return factory.last;
  }

  // ------------------------------------------------------------- readiness

  group('waiting for an offer', () {
    test('nothing is created before an offer arrives', () async {
      await becomeReady();

      // Both preconditions hold and the technician may well be in the room.
      // The device is the answerer: it waits.
      expect(factory.createCount, 0);
      expect(bloc.state, const WebRtcIdle());
      expect(signaling.sentAnswers, isEmpty);
      expect(signaling.sentIceCandidates, isEmpty);
    });

    test('the device never offers, whatever happens to the session', () async {
      await becomeReady();
      // Every cue short of an offer, in turn.
      bloc.add(const WebRtcSignalingAvailabilityChanged(testRemoteSessionId));
      bloc.add(const WebRtcRemoteSessionChanged(testRemoteSessionId));
      await settle();

      expect(factory.createCount, 0);
      expect(signaling.sentAnswers, isEmpty);
    });
  });

  // ----------------------------------------------------------- offer flow

  group('accepting an offer', () {
    test('runs the negotiation in the order WebRTC requires', () async {
      final peer = await negotiate();

      expect(factory.createCount, 1);
      expect(peer.calls, [
        'setRemoteDescription',
        'createAnswer',
        'setLocalDescription',
      ]);
      // The offer is applied exactly as relayed — never edited.
      expect(peer.remoteDescriptions.single.sdp, testSdp);
      expect(peer.remoteDescriptions.single.kind, WebRtcSdpKind.offer);
      // And the answer that was set locally is the one that went out.
      expect(peer.localDescriptions.single.sdp, testLocalAnswerSdp);
      expect(signaling.sentAnswers.single.sdp, testLocalAnswerSdp);
      expect(signaling.sentAnswers.single.remoteSessionId, testRemoteSessionId);
      expect(bloc.state, const WebRtcConnecting(testRemoteSessionId));
    });

    test('the ICE configuration is the one it was built with', () async {
      final configured = WebRtcIceConfiguration.fromStunUrl(
        'stun:stun.example.org:19302',
      );
      final scoped = WebRtcSessionBloc(
        peerConnectionFactory: factory,
        signaling: signaling,
        iceConfiguration: configured,
      );
      addTearDown(scoped.close);

      scoped.add(const WebRtcSignalingAvailabilityChanged(testRemoteSessionId));
      scoped.add(const WebRtcRemoteSessionChanged(testRemoteSessionId));
      scoped.add(WebRtcOfferReceived(offerFor()));
      await settle();

      expect(factory.configurations.single, configured);
      expect(
        factory.configurations.single.iceServers.single.urls,
        ['stun:stun.example.org:19302'],
      );
    });

    test('no ICE servers is the default, for a LAN test', () {
      expect(WebRtcIceConfiguration.fromStunUrl('').iceServers, isEmpty);
      expect(WebRtcIceConfiguration.fromStunUrl(null).iceServers, isEmpty);
      expect(WebRtcIceConfiguration.fromStunUrl('   ').iceServers, isEmpty);
    });
  });

  group('refusing an offer', () {
    test('an offer before the signaling room was joined is ignored', () async {
      bloc.add(const WebRtcRemoteSessionChanged(testRemoteSessionId));
      await settle();
      await receiveOffer();

      expect(factory.createCount, 0);
      expect(bloc.state, const WebRtcIdle());
    });

    test('an offer with no live remote session is ignored', () async {
      bloc.add(const WebRtcSignalingAvailabilityChanged(testRemoteSessionId));
      await settle();
      await receiveOffer();

      expect(factory.createCount, 0);
      expect(bloc.state, const WebRtcIdle());
    });

    test('an offer naming another session is never adopted', () async {
      await becomeReady();
      await receiveOffer(remoteSessionId: testOtherRemoteSessionId);

      // Following it would let whatever is on the other end of the socket
      // redirect this device's peer connection.
      expect(factory.createCount, 0);
      expect(bloc.state, const WebRtcIdle());
    });

    test('ICE naming another session is ignored too', () async {
      final peer = await negotiate();

      bloc.add(
        WebRtcRemoteIceReceived(
          remoteCandidate(remoteSessionId: testOtherRemoteSessionId),
        ),
      );
      await settle();

      expect(peer.addedRemoteCandidates, isEmpty);
    });

    test('the same offer twice builds one peer and one answer', () async {
      await negotiate();
      await receiveOffer();

      expect(factory.createCount, 1);
      expect(signaling.sentAnswers, hasLength(1));
    });

    test('a healthy connection is not replaced by a stray offer', () async {
      final peer = await negotiate();
      peer.pushConnectionState(WebRtcConnectionState.connected);
      await settle();
      expect(bloc.state, isA<WebRtcConnected>());

      // A different offer, and still refused: destroying a working assistance
      // session over a duplicate relay is the worse failure.
      await receiveOffer(sdp: testSecondOfferSdp);

      expect(factory.createCount, 1);
      expect(peer.isClosed, isFalse);
      expect(bloc.state, isA<WebRtcConnected>());
    });
  });

  // ------------------------------------------------------------- local ICE

  group('local ICE', () {
    test('nothing leaves before the answer was delivered', () async {
      final gate = Completer<void>();
      signaling.answerGate = gate;

      await becomeReady();
      bloc.add(WebRtcOfferReceived(offerFor()));
      await settle();

      final peer = factory.last;
      peer.pushLocalCandidate(localCandidate('candidate:A'));
      peer.pushLocalCandidate(localCandidate('candidate:B'));
      await settle();

      // The answer is still in flight: the web has no remote description yet,
      // so a candidate now is a candidate for a negotiation that has not
      // started on the other end.
      expect(signaling.sentIceCandidates, isEmpty);

      gate.complete();
      await settle();

      expect(signaling.sentIceLines, ['candidate:A', 'candidate:B']);
    });

    test('candidates gathered afterwards go out immediately, in order', () async {
      final peer = await negotiate();

      peer.pushLocalCandidate(localCandidate('candidate:A'));
      await settle();
      peer.pushLocalCandidate(localCandidate('candidate:B'));
      await settle();

      expect(signaling.sentIceLines, ['candidate:A', 'candidate:B']);
    });

    test('the candidate fields reach the wire unchanged', () async {
      final peer = await negotiate();
      peer.pushLocalCandidate(
        const PeerIceCandidate(
          candidate: testIceCandidate,
          sdpMid: 'audio',
          sdpMLineIndex: 3,
        ),
      );
      await settle();

      final sent = signaling.sentIceCandidates.single;
      expect(sent.remoteSessionId, testRemoteSessionId);
      expect(sent.candidate, testIceCandidate);
      expect(sent.sdpMid, 'audio');
      expect(sent.sdpMLineIndex, 3);
    });

    test('a refused candidate relay never closes a connection', () async {
      final peer = await negotiate();
      peer.pushConnectionState(WebRtcConnectionState.connected);
      await settle();

      signaling.candidateResult = const SignalingRelayRefused(
        SignalingErrorCode.unavailable,
      );
      peer.pushLocalCandidate(localCandidate('candidate:A'));
      await settle();

      // One candidate is one path, not the negotiation. And it is not retried.
      expect(peer.isClosed, isFalse);
      expect(bloc.state, isA<WebRtcConnected>());
      expect(signaling.sentIceCandidates, hasLength(1));
    });
  });

  // ------------------------------------------------------------ remote ICE

  group('remote ICE', () {
    test('candidates arriving before the offer is applied are queued', () async {
      // The web sends its candidates as soon as its own offer was delivered
      // and does not wait for the answer, so they routinely arrive while this
      // side is still inside setRemoteDescription.
      final gate = Completer<void>();
      factory.setRemoteDescriptionGate = gate;

      await becomeReady();
      bloc.add(WebRtcOfferReceived(offerFor()));
      await settle();

      final peer = factory.last;
      expect(peer.calls, ['setRemoteDescription']);

      bloc.add(WebRtcRemoteIceReceived(remoteCandidate(candidate: 'A')));
      bloc.add(WebRtcRemoteIceReceived(remoteCandidate(candidate: 'B')));
      await settle();

      // Held, not dropped: the two ends would otherwise try to pair with half
      // the addresses between them.
      expect(peer.addedRemoteCandidates, isEmpty);

      gate.complete();
      await settle();

      expect(
        [for (final c in peer.addedRemoteCandidates) c.candidate],
        ['A', 'B'],
      );
      // And the answer only leaves after the offer was applied.
      expect(signaling.sentAnswers, hasLength(1));
    });

    test('candidates arriving afterwards are applied in order', () async {
      final peer = await negotiate();

      bloc.add(WebRtcRemoteIceReceived(remoteCandidate(candidate: 'A')));
      await settle();
      bloc.add(WebRtcRemoteIceReceived(remoteCandidate(candidate: 'B')));
      await settle();

      expect(
        [for (final c in peer.addedRemoteCandidates) c.candidate],
        ['A', 'B'],
      );
    });

    test('an end-of-candidates marker is passed on, not refused', () async {
      final peer = await negotiate();

      // The contract allows the empty candidate; what it has to become for
      // libwebrtc is settled inside the data layer, not here.
      bloc.add(WebRtcRemoteIceReceived(remoteCandidate(candidate: '')));
      await settle();

      expect(peer.addedRemoteCandidates.single.candidate, isEmpty);
      expect(peer.addedRemoteCandidates.single.isEndOfCandidates, isTrue);
    });

    test('a candidate with no negotiation to attach it to is dropped', () async {
      await becomeReady();

      bloc.add(WebRtcRemoteIceReceived(remoteCandidate()));
      await settle();

      expect(factory.createCount, 0);
    });
  });

  // ----------------------------------------------------------- the answer

  group('the answer', () {
    test('an answer that was not delivered closes the negotiation', () async {
      signaling.answerResult = const SignalingRelayRefused(
        SignalingErrorCode.notJoined,
      );

      await becomeReady();
      await receiveOffer();

      // The web is still waiting for an answer that never arrived; this half of
      // the negotiation can only hold resources.
      expect(bloc.state, const WebRtcFailed(testRemoteSessionId));
      expect(factory.last.isClosed, isTrue);
    });

    test('an unanswered relay is not retried', () async {
      signaling.answerResult = const SignalingRelayUnanswered();

      await becomeReady();
      await receiveOffer();
      await settle();

      expect(signaling.sentAnswers, hasLength(1));
      expect(bloc.state, const WebRtcFailed(testRemoteSessionId));
    });

    test('a local ICE candidate is never sent after a failed answer', () async {
      signaling.answerResult = const SignalingRelayNotSent(
        SignalingNotSentReason.notJoined,
      );

      await becomeReady();
      await receiveOffer();
      final peer = factory.last;
      peer.pushLocalCandidate(localCandidate('candidate:A'));
      await settle();

      expect(signaling.sentIceCandidates, isEmpty);
    });

    test('a peer connection that cannot be built fails cleanly', () async {
      factory.failNextCreate = true;

      await becomeReady();
      await receiveOffer();

      expect(bloc.state, const WebRtcFailed(testRemoteSessionId));
      expect(signaling.sentAnswers, isEmpty);
    });

    test('an offer that cannot be applied fails the negotiation', () async {
      factory.failSetRemoteDescription = true;

      await becomeReady();
      await receiveOffer();

      // What matters is that the failure leaves nothing half-built behind, and
      // that no answer was invented for an offer that was never applied.
      expect(bloc.state, const WebRtcFailed(testRemoteSessionId));
      expect(factory.last.isClosed, isTrue);
      expect(signaling.sentAnswers, isEmpty);
    });
  });

  // ---------------------------------------------------------- data channel

  group('the control data channel', () {
    test('the device never creates one; it is given one', () async {
      final peer = await negotiate();
      expect(bloc.state.controlChannel, isNull);

      final channel = peer.pushDataChannel();
      await settle();

      expect(channel.isClosed, isFalse);
      expect(bloc.state.controlChannel, WebRtcDataChannelState.connecting);
    });

    test('an unexpected label is closed and ignored', () async {
      final peer = await negotiate();

      final channel = peer.pushDataChannel(label: 'telemetry');
      await settle();

      expect(channel.isClosed, isTrue);
      expect(bloc.state.controlChannel, isNull);
    });

    test('a second control channel does not replace the first', () async {
      final peer = await negotiate();
      final first = peer.pushDataChannel();
      await settle();
      first.pushState(WebRtcDataChannelState.open);
      await settle();

      final second = peer.pushDataChannel();
      await settle();

      expect(second.isClosed, isTrue);
      expect(first.isClosed, isFalse);
      // The state still follows the channel that was kept.
      expect(bloc.state.controlChannel, WebRtcDataChannelState.open);
      second.pushState(WebRtcDataChannelState.closed);
      await settle();
      expect(bloc.state.controlChannel, WebRtcDataChannelState.open);
    });

    test('every channel state is reported', () async {
      final peer = await negotiate();
      final channel = peer.pushDataChannel();
      await settle();
      expect(bloc.state.controlChannel, WebRtcDataChannelState.connecting);

      for (final state in [
        WebRtcDataChannelState.open,
        WebRtcDataChannelState.closing,
        WebRtcDataChannelState.closed,
      ]) {
        channel.pushState(state);
        await settle();
        expect(bloc.state.controlChannel, state);
      }
    });

    test('messages are surfaced and nothing is executed', () async {
      final peer = await negotiate();
      final channel = peer.pushDataChannel();
      await settle();
      channel.pushState(WebRtcDataChannelState.open);
      await settle();

      final received = <WebRtcDataChannelMessage>[];
      final subscription = bloc.controlMessages.listen(received.add);
      addTearDown(subscription.cancel);

      channel.pushMessage(const WebRtcDataChannelMessage.text('{"tap":1}'));
      await settle();

      // Read, never acted on: there is no control protocol and no Android side
      // in this build.
      expect(received, hasLength(1));
      expect(received.single.text, '{"tap":1}');
    });

    test('a connected peer with an open channel is the success condition',
        () async {
      final peer = await negotiate();
      peer.pushConnectionState(WebRtcConnectionState.connected);
      await settle();
      // Connected alone is not enough.
      expect(bloc.state.isRemoteConnectionEstablished, isFalse);

      final channel = peer.pushDataChannel();
      await settle();
      channel.pushState(WebRtcDataChannelState.open);
      await settle();

      expect(bloc.state, isA<WebRtcConnected>());
      expect(bloc.state.isRemoteConnectionEstablished, isTrue);
    });

    test('an open channel alone is not enough either', () async {
      final peer = await negotiate();
      final channel = peer.pushDataChannel();
      await settle();
      channel.pushState(WebRtcDataChannelState.open);
      await settle();

      expect(bloc.state, isA<WebRtcConnecting>());
      expect(bloc.state.isRemoteConnectionEstablished, isFalse);
    });
  });

  // ------------------------------------------------------ connection states

  group('connection states', () {
    test('every state WebRTC defines has a name here', () {
      // The mapping in the data layer is exhaustive over libwebrtc's enum, so
      // a value added there cannot be silently folded into another one. This
      // is the list it maps onto.
      expect(WebRtcConnectionState.values, [
        WebRtcConnectionState.initial,
        WebRtcConnectionState.connecting,
        WebRtcConnectionState.connected,
        WebRtcConnectionState.disconnected,
        WebRtcConnectionState.failed,
        WebRtcConnectionState.closed,
      ]);
      expect(WebRtcDataChannelState.values, [
        WebRtcDataChannelState.connecting,
        WebRtcDataChannelState.open,
        WebRtcDataChannelState.closing,
        WebRtcDataChannelState.closed,
      ]);
    });

    test('new says nothing while the negotiation is still being set up',
        () async {
      final peer = await negotiate();

      // `new` before anything connected is the state the connection was
      // created in; it does not undo the answer that was just relayed.
      peer.pushConnectionState(WebRtcConnectionState.initial);
      await settle();

      expect(bloc.state, const WebRtcConnecting(testRemoteSessionId));
      expect(peer.isClosed, isFalse);
    });

    test('a connected peer restarting its transports reads as connecting',
        () async {
      final peer = await negotiate();
      peer.pushConnectionState(WebRtcConnectionState.connected);
      await settle();

      peer.pushConnectionState(WebRtcConnectionState.initial);
      await settle();

      expect(bloc.state, const WebRtcConnecting(testRemoteSessionId));
    });

    test('connected, interrupted and back again', () async {
      final peer = await negotiate();

      peer.pushConnectionState(WebRtcConnectionState.connecting);
      await settle();
      expect(bloc.state, const WebRtcConnecting(testRemoteSessionId));

      peer.pushConnectionState(WebRtcConnectionState.connected);
      await settle();
      expect(bloc.state, const WebRtcConnected(testRemoteSessionId));

      // Possibly transient: nothing is torn down and no timer is started.
      peer.pushConnectionState(WebRtcConnectionState.disconnected);
      await settle();
      expect(bloc.state, const WebRtcInterrupted(testRemoteSessionId));
      expect(peer.isClosed, isFalse);

      peer.pushConnectionState(WebRtcConnectionState.connected);
      await settle();
      expect(bloc.state, const WebRtcConnected(testRemoteSessionId));
    });

    test('failed closes the negotiation and starts nothing', () async {
      final peer = await negotiate();

      peer.pushConnectionState(WebRtcConnectionState.failed);
      await settle();

      expect(bloc.state, const WebRtcFailed(testRemoteSessionId));
      expect(peer.isClosed, isTrue);
      expect(factory.createCount, 1);
    });

    test('closed by the peer is recorded, not recovered from', () async {
      final peer = await negotiate();

      peer.pushConnectionState(WebRtcConnectionState.closed);
      await settle();

      expect(bloc.state, const WebRtcClosed(testRemoteSessionId));
      expect(factory.createCount, 1);
    });
  });

  // --------------------------------------------------------- signaling loss

  group('losing signaling', () {
    test('a negotiation that has not connected is abandoned', () async {
      final peer = await negotiate();

      bloc.add(const WebRtcSignalingAvailabilityChanged(null));
      await settle();

      expect(bloc.state, const WebRtcIdle());
      expect(peer.isClosed, isTrue);
    });

    test('and the device then waits for a new offer, never making one',
        () async {
      await negotiate();
      bloc.add(const WebRtcSignalingAvailabilityChanged(null));
      await settle();

      // The socket comes back and rejoins.
      bloc.add(const WebRtcSignalingAvailabilityChanged(testRemoteSessionId));
      await settle();

      expect(factory.createCount, 1);
      expect(bloc.state, const WebRtcIdle());

      // Only a new offer starts anything.
      await receiveOffer(sdp: testSecondOfferSdp);
      expect(factory.createCount, 2);
    });

    test('a connected peer is left alone', () async {
      final peer = await negotiate();
      peer.pushConnectionState(WebRtcConnectionState.connected);
      final channel = peer.pushDataChannel();
      await settle();
      channel.pushState(WebRtcDataChannelState.open);
      await settle();

      bloc.add(const WebRtcSignalingAvailabilityChanged(null));
      await settle();

      // WebRTC is peer to peer; the socket only introduced the two ends.
      expect(peer.isClosed, isFalse);
      expect(channel.isClosed, isFalse);
      expect(bloc.state.isRemoteConnectionEstablished, isTrue);
    });

    test('a reconnect does not renegotiate a healthy peer', () async {
      final peer = await negotiate();
      peer.pushConnectionState(WebRtcConnectionState.connected);
      await settle();

      bloc.add(const WebRtcSignalingAvailabilityChanged(null));
      bloc.add(const WebRtcSignalingAvailabilityChanged(testRemoteSessionId));
      await settle();

      expect(factory.createCount, 1);
      expect(signaling.sentAnswers, hasLength(1));
    });
  });

  // --------------------------------------------------------- renegotiation

  group('a new negotiation after a failure', () {
    test('a new offer builds a second generation', () async {
      final first = await negotiate();
      first.pushConnectionState(WebRtcConnectionState.failed);
      await settle();
      expect(bloc.state, const WebRtcFailed(testRemoteSessionId));

      // The web reloaded, rejoined and offered again.
      await receiveOffer(sdp: testSecondOfferSdp);

      expect(factory.createCount, 2);
      expect(signaling.sentAnswers, hasLength(2));
      expect(bloc.state, const WebRtcConnecting(testRemoteSessionId));
    });

    test('a late callback from the old generation is ignored', () async {
      final first = await negotiate();
      first.pushConnectionState(WebRtcConnectionState.failed);
      await settle();
      await receiveOffer(sdp: testSecondOfferSdp);
      factory.last.pushConnectionState(WebRtcConnectionState.connected);
      await settle();
      expect(bloc.state, const WebRtcConnected(testRemoteSessionId));

      // The first negotiation is generation 1 — the first offer bumps 0 to 1 —
      // and everything after it moved on. A real connection keeps reporting
      // for as long as its native side is winding down, and those reports are
      // already queued as events by the time the generation changes, so they
      // arrive exactly like this.
      bloc.add(
        const WebRtcConnectionStateChanged(1, WebRtcConnectionState.failed),
      );
      bloc.add(WebRtcLocalIceProduced(1, localCandidate('candidate:stale')));
      await settle();

      expect(bloc.state, const WebRtcConnected(testRemoteSessionId));
      expect(signaling.sentIceLines, isNot(contains('candidate:stale')));
    });

    test('a data channel from an old generation is closed, never kept',
        () async {
      await negotiate();
      expect(bloc.state.controlChannel, isNull);

      final stale = FakeWebRtcDataChannel(label: controlDataChannelLabel);
      // Generation 0 can never be current: the first offer already bumped it.
      bloc.add(WebRtcDataChannelOffered(0, stale));
      await settle();

      expect(stale.isClosed, isTrue);
      expect(bloc.state.controlChannel, isNull);
    });

    test('an offer after the peer closed builds a new one', () async {
      final first = await negotiate();
      first.pushConnectionState(WebRtcConnectionState.closed);
      await settle();

      await receiveOffer(sdp: testSecondOfferSdp);

      expect(factory.createCount, 2);
      expect(first.isClosed, isTrue);
    });
  });

  // ------------------------------------------------------------- teardown

  group('the remote session ending', () {
    test('closes everything and empties the queues', () async {
      final gate = Completer<void>();
      signaling.answerGate = gate;
      await becomeReady();
      bloc.add(WebRtcOfferReceived(offerFor()));
      await settle();

      final peer = factory.last;
      final channel = peer.pushDataChannel();
      await settle();
      peer.pushLocalCandidate(localCandidate('candidate:A'));
      await settle();
      // Queued, not sent: the answer has not been delivered.
      expect(signaling.sentIceCandidates, isEmpty);

      bloc.add(const WebRtcRemoteSessionChanged(null));
      await settle();
      gate.complete();
      await settle();

      expect(bloc.state, const WebRtcIdle());
      expect(peer.isClosed, isTrue);
      expect(channel.isClosed, isTrue);
      // The queue went with the negotiation: a candidate for a session that is
      // over is never relayed.
      expect(signaling.sentIceCandidates, isEmpty);
    });

    test('a connected peer does not outlive its remote session', () async {
      final peer = await negotiate();
      peer.pushConnectionState(WebRtcConnectionState.connected);
      final channel = peer.pushDataChannel();
      await settle();
      channel.pushState(WebRtcDataChannelState.open);
      await settle();
      expect(bloc.state.isRemoteConnectionEstablished, isTrue);

      bloc.add(const WebRtcRemoteSessionChanged(null));
      await settle();

      expect(bloc.state, const WebRtcIdle());
      expect(peer.isClosed, isTrue);
      expect(channel.isClosed, isTrue);
    });

    test('a different session replaces the negotiation entirely', () async {
      final peer = await negotiate();

      bloc.add(const WebRtcRemoteSessionChanged(testOtherRemoteSessionId));
      await settle();

      expect(bloc.state, const WebRtcIdle());
      expect(peer.isClosed, isTrue);
    });

    test('closing the bloc releases the peer and the channel', () async {
      final peer = await negotiate();
      final channel = peer.pushDataChannel();
      await settle();

      await bloc.close();

      expect(peer.isClosed, isTrue);
      expect(channel.isClosed, isTrue);
    });

    test('repeated teardown is harmless', () async {
      final peer = await negotiate();

      bloc.add(const WebRtcRemoteSessionChanged(null));
      await settle();
      bloc.add(const WebRtcRemoteSessionChanged(null));
      await settle();
      bloc.add(const WebRtcSignalingAvailabilityChanged(null));
      await settle();

      expect(bloc.state, const WebRtcIdle());
      expect(peer.closeCount, 1);
    });
  });

  // -------------------------------------------------------- logging safety

  group('logging safety', () {
    test('no WebRTC model can print an SDP or a candidate line', () async {
      const description = WebRtcSessionDescription.offer(testSdp);
      const candidate = PeerIceCandidate(candidate: testIceCandidate);
      const message = WebRtcDataChannelMessage.text('secret payload');

      expect('$description', isNot(contains(testSdp)));
      expect('$candidate', isNot(contains(testIceCandidate)));
      expect('$message', isNot(contains('secret payload')));
    });

    test('a state prints its session id and nothing else', () {
      const state = WebRtcConnected(testRemoteSessionId);
      expect('$state', contains(testRemoteSessionId));
      expect('$state', isNot(contains(testSdp)));
    });
  });
}
