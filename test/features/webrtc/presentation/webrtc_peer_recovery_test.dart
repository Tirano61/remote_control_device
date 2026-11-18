import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/screen_capture/data/media_projection_screen_capture_client.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_capture_result.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_capture_status.dart';
import 'package:remote_control_device/features/screen_capture/domain/screen_capture_client.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_message.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_device/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../../../fakes/manual_timers.dart';
import '../../../fakes/remote_control_fakes.dart';
import '../../../fakes/remote_session_fakes.dart';
import '../../../fakes/screen_capture_fakes.dart';
import '../../../fakes/signaling_fakes.dart';
import '../../../fakes/webrtc_fakes.dart';

/// The web's `RTCPeerConnection` failed, its console checked REST and found the
/// same session still ACTIVE, closed that connection and built a new one, and
/// offered again — while this side still read its own peer as CONNECTED.
///
/// That offer used to be ignored and the web waited for an answer forever
/// (Prompt 23 WEB, E2E F, on the T10A). These tests are that scenario and
/// everything around it: which offers may replace a peer, what the old peer
/// leaves behind, what the screen does, and the races.
///
/// Each web connection is told apart by the identity in its SDP `o=` line.
const String offerA = testSdp; // o=- 46117 2
const String offerB = testSecondOfferSdp; // o=- 77777 2
const String offerC = 'v=0\r\no=- 55555 2 IN IP4 127.0.0.1\r\n';

/// The connection of [offerA] renegotiating: same identity, next version.
const String offerARenegotiated = 'v=0\r\no=- 46117 3 IN IP4 127.0.0.1\r\n';

void main() {
  late FakeWebRtcPeerConnectionFactory factory;
  late FakeWebRtcSignalingGateway signaling;
  late FakeRemoteControlAccessibilityClient accessibility;
  late ManualTimers timers;
  late ScreenCaptureClient screenCapture;
  late WebRtcSessionBloc bloc;

  WebRtcSessionBloc build(ScreenCaptureClient capture) {
    screenCapture = capture;
    return WebRtcSessionBloc(
      peerConnectionFactory: factory,
      signaling: signaling,
      iceConfiguration: const WebRtcIceConfiguration.none(),
      screenCapture: capture,
      remoteControl: accessibility,
      timerFactory: timers.factory,
    );
  }

  setUp(() {
    factory = FakeWebRtcPeerConnectionFactory();
    signaling = FakeWebRtcSignalingGateway();
    accessibility = FakeRemoteControlAccessibilityClient();
    timers = ManualTimers();
    bloc = build(FakeScreenCaptureClient());
  });

  tearDown(() async => bloc.close());

  Future<void> settle() async {
    for (var i = 0; i < 16; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  FakeScreenCaptureClient fakeCapture() =>
      screenCapture as FakeScreenCaptureClient;

  /// What the coordinator forwards for a session in the given condition.
  void session({
    required String? live,
    required String? confirmed,
    required String? active,
  }) {
    bloc
      ..add(WebRtcActiveRemoteSessionChanged(active))
      ..add(WebRtcRemoteSessionAuthorityChanged(confirmed))
      ..add(WebRtcRemoteSessionChanged(live));
  }

  void activeConfirmed() => session(
    live: testRemoteSessionId,
    confirmed: testRemoteSessionId,
    active: testRemoteSessionId,
  );

  void activeSuspended() =>
      session(live: testRemoteSessionId, confirmed: null, active: null);

  void closed() => session(live: null, confirmed: null, active: null);

  Future<void> offer(String sdp) async {
    bloc.add(WebRtcOfferReceived(offerFor(sdp: sdp)));
    await settle();
  }

  /// Brings the newest peer up: connected, control channel open.
  Future<(FakeWebRtcPeerConnection, FakeWebRtcDataChannel)>
  connectLast() async {
    final peer = factory.last;
    peer.pushConnectionState(WebRtcConnectionState.connected);
    final channel = peer.pushDataChannel();
    await settle();
    channel.pushState(WebRtcDataChannelState.open);
    await settle();
    return (peer, channel);
  }

  /// RemoteSession ACTIVE and confirmed, the device's peer CONNECTED, the
  /// control channel open, the screen shared, one tap obeyed.
  Future<(FakeWebRtcPeerConnection, FakeWebRtcDataChannel)>
  reachActive() async {
    bloc.add(const WebRtcSignalingAvailabilityChanged(testRemoteSessionId));
    activeConfirmed();
    await settle();
    await offer(offerA);
    final (peer, channel) = await connectLast();
    channel.pushTap('before');
    await settle();
    expect(accessibility.taps, hasLength(1));
    expect(bloc.state.isRemoteConnectionEstablished, isTrue);
    return (peer, channel);
  }

  void pushHold(FakeWebRtcDataChannel channel) => channel.pushFrame(
    const WebRtcDataChannelMessage.text(
      '{"v":1,"type":"touch_hold","id":"hold-1","touch":"t-1",'
      '"x":0.41,"y":0.52}',
    ),
  );

  // -------------------------------------------------------- the E2E F case

  group('web peer FAILED, device peer still CONNECTED', () {
    test('a new valid offer replaces the old peer, is answered, and the new '
        'connection carries control', () async {
      final (old, oldChannel) = await reachActive();
      expect(bloc.state, isA<WebRtcConnected>());

      // The web's connection failed; the device has not noticed. The web's
      // console confirmed the session over REST and offers from a new one.
      await offer(offerB);

      expect(old.isClosed, isTrue);
      expect(oldChannel.isClosed, isTrue);
      expect(factory.createCount, 2);
      expect(factory.last.remoteDescriptions.single.sdp, offerB);
      expect(signaling.sentAnswers, hasLength(2));
      expect(signaling.sentAnswers.last.remoteSessionId, testRemoteSessionId);
      expect(
        bloc.state,
        const WebRtcConnecting(
          testRemoteSessionId,
          screenCapture: ScreenCaptureStatus.active,
        ),
      );

      final (_, channel) = await connectLast();
      expect(bloc.state.isRemoteConnectionEstablished, isTrue);
      channel.pushTap('after');
      await settle();

      expect(accessibility.taps, hasLength(2));
      expect(channel.sentAcks, const [RemoteControlAck.success('after')]);
    });

    test('the old peer is closed before the new one is built', () async {
      final (old, oldChannel) = await reachActive();
      final gate = Completer<void>();
      factory.createGate = gate;

      bloc.add(WebRtcOfferReceived(offerFor(sdp: offerB)));
      await settle();

      // The new connection is being created, and the old one is already gone.
      expect(factory.configurations, hasLength(2));
      expect(factory.createCount, 1);
      expect(old.isClosed, isTrue);
      expect(oldChannel.isClosed, isTrue);

      gate.complete();
      await settle();
      expect(factory.createCount, 2);
    });

    test('a recovery during CONNECTING is accepted with confirmed authority, '
        'and still obeys nothing', () async {
      bloc.add(const WebRtcSignalingAvailabilityChanged(testRemoteSessionId));
      session(
        live: testRemoteSessionId,
        confirmed: testRemoteSessionId,
        active: null,
      );
      await settle();
      await offer(offerA);
      await connectLast();

      await offer(offerB);
      final (_, channel) = await connectLast();
      channel.pushTap('connecting');
      await settle();

      expect(factory.createCount, 2);
      expect(accessibility.taps, isEmpty);
      expect(channel.sentAcks, const [
        RemoteControlAck.failure(
          'connecting',
          RemoteControlError.sessionNotActive,
        ),
      ]);
    });
  });

  // --------------------------------------------------- which offers count

  group('telling offers apart', () {
    test('the same offer again is a repeat: no second peer, no second '
        'answer', () async {
      final (peer, _) = await reachActive();

      await offer(offerA);

      expect(factory.createCount, 1);
      expect(signaling.sentAnswers, hasLength(1));
      expect(peer.isClosed, isFalse);
    });

    test('an offer from a connection already replaced is stale', () async {
      await reachActive();
      await offer(offerB);
      final (current, _) = await connectLast();

      // A late relay of the connection the web gave up on.
      await offer(offerA);

      expect(factory.createCount, 2);
      expect(signaling.sentAnswers, hasLength(2));
      expect(current.isClosed, isFalse);
      expect(bloc.state.isRemoteConnectionEstablished, isTrue);
    });

    test('a stale offer is not answered after a failure either', () async {
      final (peer, _) = await reachActive();
      peer.pushConnectionState(WebRtcConnectionState.failed);
      await settle();

      // No peer left to replace, and still the offer of a connection that
      // already failed: nothing waits for its answer.
      await offer(offerA);

      expect(factory.createCount, 1);
      expect(signaling.sentAnswers, hasLength(1));
    });

    test('a renegotiation of the connection already answered is not '
        'something this build does', () async {
      final (peer, _) = await reachActive();

      await offer(offerARenegotiated);

      expect(factory.createCount, 1);
      expect(peer.isClosed, isFalse);
      expect(bloc.state.isRemoteConnectionEstablished, isTrue);
    });

    test('an offer with no readable SDP origin is ignored', () async {
      final (peer, _) = await reachActive();

      await offer('v=0\r\ns=-\r\n');

      expect(factory.createCount, 1);
      expect(peer.isClosed, isFalse);
    });

    test('a closed session takes the peer, and no offer rebuilds it', () async {
      final (peer, _) = await reachActive();
      closed();
      await settle();
      expect(peer.isClosed, isTrue);

      await offer(offerB);

      expect(factory.createCount, 1);
      expect(signaling.sentAnswers, hasLength(1));
      expect(bloc.state, const WebRtcIdle());
    });

    test('suspended authority: the recovery is refused and the old peer is '
        'kept, under the suspension rules', () async {
      final (peer, channel) = await reachActive();
      activeSuspended();
      await settle();

      await offer(offerB);

      expect(factory.createCount, 1);
      expect(peer.isClosed, isFalse);
      expect(channel.isClosed, isFalse);
      expect(signaling.sentAnswers, hasLength(1));
      channel.pushTap('suspended');
      await settle();
      expect(accessibility.taps, hasLength(1));
    });

    test('a refused recovery can be made again once authority is back, by a '
        'new connection', () async {
      await reachActive();
      activeSuspended();
      await settle();
      await offer(offerB);
      expect(factory.createCount, 1);

      activeConfirmed();
      await settle();
      // Offer B was never accepted, so it is not stale: if the web resends it
      // it is answered now.
      await offer(offerB);

      expect(factory.createCount, 2);
      expect(signaling.sentAnswers, hasLength(2));
    });

    test('an offer for another session never replaces this one', () async {
      final (peer, _) = await reachActive();

      bloc.add(
        WebRtcOfferReceived(
          offerFor(remoteSessionId: testOtherRemoteSessionId, sdp: offerB),
        ),
      );
      await settle();

      expect(factory.createCount, 1);
      expect(peer.isClosed, isFalse);
    });

    test('once Android stopped the capture, no recovery is answered', () async {
      final (peer, _) = await reachActive();
      fakeCapture().endFromPlatform();
      await settle();
      expect(peer.isClosed, isTrue);

      await offer(offerB);

      expect(factory.createCount, 1);
      expect(fakeCapture().requests, [testRemoteSessionId]);
    });
  });

  // ------------------------------------------- what the old peer leaves

  group('what the old peer leaves behind', () {
    test('a DRAG is abandoned, never released', () async {
      final (_, oldChannel) = await reachActive();
      pushHold(oldChannel);
      await settle();
      accessibility.answerStart();
      await settle();
      final handle =
          (accessibility.touchCalls.single as (String, int, double, double)).$2;

      await offer(offerB);

      expect(accessibility.touchCalls.last, ('abandon', handle));
      expect(
        accessibility.touchCalls
            .whereType<(String, int, int, double, double)>(),
        isEmpty,
      );
      // Its release, arriving late on the old channel, reaches nothing.
      oldChannel.pushFrame(
        const WebRtcDataChannelMessage.text(
          '{"v":1,"type":"touch_release","id":"rel-1","touch":"t-1",'
          '"seq":1,"x":0.6,"y":0.7}',
        ),
      );
      await settle();
      expect(
        accessibility.touchCalls
            .whereType<(String, int, int, double, double)>(),
        isEmpty,
      );
    });

    test('queued commands are dropped and never run on any peer', () async {
      final (_, oldChannel) = await reachActive();
      accessibility.holdGestures = true;
      oldChannel
        ..pushTap('running')
        ..pushTap('queued');
      await settle();
      expect(accessibility.taps, hasLength(2));

      await offer(offerB);
      accessibility.finishGesture();
      await settle();
      final (_, channel) = await connectLast();
      await settle();

      // 'running' had already reached Android and could not be recalled;
      // 'queued' never did, and never will.
      expect(accessibility.taps, hasLength(2));
      expect(
        oldChannel.sentAcks,
        isNot(contains(const RemoteControlAck.success('queued'))),
      );
      expect(channel.sentAcks, isEmpty);
    });

    test('the old channel delivers nothing, and only the new one is '
        'obeyed', () async {
      final (_, oldChannel) = await reachActive();
      await offer(offerB);
      final (_, channel) = await connectLast();

      oldChannel.pushTap('old');
      channel.pushTap('new');
      await settle();

      expect(accessibility.taps, hasLength(2));
      expect(
        oldChannel.sentAcks,
        isNot(
          contains(
            isA<RemoteControlAck>().having((ack) => ack.id, 'id', 'old'),
          ),
        ),
      );
      expect(channel.sentAcks, const [RemoteControlAck.success('new')]);
    });

    test('the old peer turning FAILED after the new one exists changes '
        'nothing', () async {
      await reachActive();
      await offer(offerB);
      final (current, _) = await connectLast();

      // Generation 1 is the first offer; the recovery is generation 2.
      bloc
        ..add(
          const WebRtcConnectionStateChanged(1, WebRtcConnectionState.failed),
        )
        ..add(
          const WebRtcConnectionStateChanged(1, WebRtcConnectionState.closed),
        );
      await settle();

      expect(current.isClosed, isFalse);
      expect(bloc.state, isA<WebRtcConnected>());
      expect(bloc.state.isRemoteConnectionEstablished, isTrue);
    });

    test('ICE of the old peer never reaches the wire', () async {
      await reachActive();
      await offer(offerB);
      await connectLast();

      bloc.add(WebRtcLocalIceProduced(1, localCandidate('candidate:old')));
      await settle();

      expect(signaling.sentIceLines, isNot(contains('candidate:old')));
    });

    test('a data channel of the old peer is closed, never adopted', () async {
      await reachActive();
      await offer(offerB);
      final (_, channel) = await connectLast();

      final stale = FakeWebRtcDataChannel(label: 'control');
      bloc.add(WebRtcDataChannelOffered(1, stale));
      await settle();

      expect(stale.isClosed, isTrue);
      channel.pushTap('new');
      await settle();
      expect(channel.sentAcks, const [RemoteControlAck.success('new')]);
    });

    test('remote ICE sent right after the new offer reaches the new peer, '
        'even while it is being built', () async {
      final (old, _) = await reachActive();
      final gate = Completer<void>();
      factory.createGate = gate;

      bloc
        ..add(WebRtcOfferReceived(offerFor(sdp: offerB)))
        ..add(
          WebRtcRemoteIceReceived(remoteCandidate(candidate: 'cand:new-1')),
        );
      await settle();
      bloc.add(
        WebRtcRemoteIceReceived(remoteCandidate(candidate: 'cand:new-2')),
      );
      await settle();
      gate.complete();
      await settle();

      expect(old.addedRemoteCandidates, isEmpty);
      expect(
        [for (final c in factory.last.addedRemoteCandidates) c.candidate],
        ['cand:new-1', 'cand:new-2'],
      );
    });
  });

  test('a candidate still being applied to the old peer does not hold up '
      'the new one', () async {
    final (old, _) = await reachActive();
    final stuck = Completer<void>();
    old.addRemoteIceCandidateGate = stuck;
    bloc.add(WebRtcRemoteIceReceived(remoteCandidate(candidate: 'cand:old')));
    await settle();
    expect(old.addedRemoteCandidates, hasLength(1));

    bloc
      ..add(WebRtcOfferReceived(offerFor(sdp: offerB)))
      ..add(WebRtcRemoteIceReceived(remoteCandidate(candidate: 'cand:new')));
    await settle();

    // The old peer's apply has still not returned, and the new peer already
    // has its candidate.
    expect(
      [for (final c in factory.last.addedRemoteCandidates) c.candidate],
      ['cand:new'],
    );
    stuck.complete();
    await settle();
    expect(old.addedRemoteCandidates, hasLength(1));
  });

  // ----------------------------------------------------------------- races

  group('races', () {
    test('remote-session:closed while the recovery is being built', () async {
      final (old, _) = await reachActive();
      final gate = Completer<void>();
      factory.createGate = gate;

      bloc.add(WebRtcOfferReceived(offerFor(sdp: offerB)));
      await settle();
      closed();
      await settle();
      gate.complete();
      await settle();

      expect(old.isClosed, isTrue);
      // Built, found abandoned, closed: never answered.
      expect(factory.last.isClosed, isTrue);
      expect(signaling.sentAnswers, hasLength(1));
      expect(fakeCapture().isActive, isFalse);
      expect(bloc.state, const WebRtcIdle());
    });

    test('FINALIZAR while the recovery answer is in flight', () async {
      await reachActive();
      final gate = Completer<void>();
      signaling.answerGate = gate;

      bloc.add(WebRtcOfferReceived(offerFor(sdp: offerB)));
      await settle();
      final recovering = factory.last;
      recovering.pushLocalCandidate(localCandidate('candidate:after-end'));
      // FINALIZAR: the session stops being live on the tablet at once.
      closed();
      await settle();
      gate.complete();
      await settle();

      expect(recovering.isClosed, isTrue);
      expect(signaling.sentIceLines, isNot(contains('candidate:after-end')));
      expect(fakeCapture().isActive, isFalse);
      expect(bloc.state, const WebRtcIdle());

      // And a further offer for the ended session is refused.
      await offer(offerC);
      expect(factory.createCount, 2);
    });

    test('two recovery offers in a row: the last one wins, the first is '
        'never answered', () async {
      final (old, _) = await reachActive();
      final gate = Completer<void>();
      factory.createGate = gate;

      bloc
        ..add(WebRtcOfferReceived(offerFor(sdp: offerB)))
        ..add(WebRtcOfferReceived(offerFor(sdp: offerC)));
      await settle();
      gate.complete();
      await settle();

      expect(old.isClosed, isTrue);
      final open = factory.created.where((peer) => !peer.isClosed).toList();
      expect(open, hasLength(1));
      expect(open.single.remoteDescriptions.single.sdp, offerC);
      expect(signaling.sentAnswers, hasLength(2));

      // B is stale from now on.
      await offer(offerB);
      expect(factory.created.where((peer) => !peer.isClosed), hasLength(1));
    });

    test('authority suspended during the recovery: it completes, and obeys '
        'nothing until confirmed again', () async {
      await reachActive();
      final gate = Completer<void>();
      signaling.answerGate = gate;

      bloc.add(WebRtcOfferReceived(offerFor(sdp: offerB)));
      await settle();
      activeSuspended();
      await settle();
      gate.complete();
      await settle();
      final (_, channel) = await connectLast();

      channel.pushTap('suspended');
      await settle();
      expect(accessibility.taps, hasLength(1));
      expect(channel.sentAcks, const [
        RemoteControlAck.failure(
          'suspended',
          RemoteControlError.sessionNotActive,
        ),
      ]);

      activeConfirmed();
      await settle();
      channel.pushTap('confirmed');
      await settle();
      expect(accessibility.taps, hasLength(2));
    });

    test('a recovery while the Android dialog of the first offer is open: one '
        'dialog, and the late grant goes to the new peer only', () async {
      await bloc.close();
      final platform = FakeScreenCapturePlatform()
        ..consentGate = Completer<void>();
      bloc = build(
        MediaProjectionScreenCaptureClient(
          consent: platform.consent,
          foregroundService: platform.foregroundService,
          mediaSource: platform.mediaSource,
        ),
      );
      bloc.add(const WebRtcSignalingAvailabilityChanged(testRemoteSessionId));
      activeConfirmed();
      await settle();

      await offer(offerA);
      final first = factory.last;
      await offer(offerB);
      platform.consentGate!.complete();
      await settle();

      expect(platform.calls.where((c) => c == 'consent.request'), hasLength(1));
      expect(first.isClosed, isTrue);
      expect(first.attachedScreenTracks, isEmpty);
      expect(first.calls, isNot(contains('createAnswer')));
      expect(factory.last.attachedScreenTracks, [testScreenVideoTrack]);
      expect(signaling.sentAnswers, hasLength(1));
      expect(bloc.state.screenCapture, ScreenCaptureStatus.active);
    });
  });

  // ------------------------------------------------------ MediaProjection

  group('MediaProjection across a recovery', () {
    test('a running capture is reused with no new consent, and outlives the '
        'orphan window', () async {
      await bloc.close();
      final platform = FakeScreenCapturePlatform();
      bloc = build(
        MediaProjectionScreenCaptureClient(
          consent: platform.consent,
          foregroundService: platform.foregroundService,
          mediaSource: platform.mediaSource,
        ),
      );
      await reachActive();

      await offer(offerB);
      await connectLast();
      timers.elapse(WebRtcSessionBloc.defaultOrphanCaptureTimeout * 3);
      await settle();

      expect(platform.calls.where((c) => c == 'consent.request'), hasLength(1));
      expect(
        platform.calls.where((c) => c == 'mediaSource.open'),
        hasLength(1),
      );
      expect(platform.lastCapture.isDisposed, isFalse);
      expect(factory.last.attachedScreenTracks, [testScreenVideoTrack]);
      expect(screenCapture.isActive, isTrue);
      expect(bloc.state.screenCapture, ScreenCaptureStatus.active);
    });

    test('a capture that is not running is not revived silently: Android is '
        'asked again', () async {
      await bloc.close();
      final platform = FakeScreenCapturePlatform()..granted = false;
      bloc = build(
        MediaProjectionScreenCaptureClient(
          consent: platform.consent,
          foregroundService: platform.foregroundService,
          mediaSource: platform.mediaSource,
        ),
      );
      bloc.add(const WebRtcSignalingAvailabilityChanged(testRemoteSessionId));
      activeConfirmed();
      await settle();
      await offer(offerA);
      await connectLast();
      expect(bloc.state.screenCapture, ScreenCaptureStatus.denied);

      platform.granted = true;
      await offer(offerB);

      // A new dialog, which the user answers; never a capture without one.
      expect(platform.calls.where((c) => c == 'consent.request'), hasLength(2));
      expect(
        platform.calls.where((c) => c == 'mediaSource.open'),
        hasLength(1),
      );
      expect(bloc.state.screenCapture, ScreenCaptureStatus.active);
    });

    test('a capture stopped while nobody received it is asked for again on '
        'the next offer', () async {
      final capture = fakeCapture();
      final (peer, _) = await reachActive();
      peer.pushConnectionState(WebRtcConnectionState.failed);
      await settle();
      timers.elapse(WebRtcSessionBloc.defaultOrphanCaptureTimeout);
      await settle();
      expect(capture.isActive, isFalse);

      await offer(offerB);

      expect(capture.requests, [testRemoteSessionId, testRemoteSessionId]);
      expect(capture.stopCount, 1);
    });

    test('a refused capture on the recovery still answers, without the '
        'screen', () async {
      await reachActive();
      fakeCapture().result = const ScreenCaptureDenied();
      await fakeCapture().stop();

      await offer(offerB);

      expect(signaling.sentAnswers, hasLength(2));
      expect(bloc.state.screenCapture, ScreenCaptureStatus.denied);
    });
  });
}
