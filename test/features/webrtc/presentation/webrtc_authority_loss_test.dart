import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_capture_status.dart';
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

/// What the WebRTC layer does on its own when the thing carrying the
/// assistance goes away underneath it: the peer connection fails or is closed
/// by the other end, or Android takes the screen away (MediaProjection
/// `onStop`).
///
/// Every deadline runs on [ManualTimers]: nothing here waits for wall time.
void main() {
  late FakeWebRtcPeerConnectionFactory factory;
  late FakeWebRtcSignalingGateway signaling;
  late FakeScreenCaptureClient screenCapture;
  late FakeRemoteControlAccessibilityClient accessibility;
  late ManualTimers timers;
  late WebRtcSessionBloc bloc;

  const orphanTimeout = WebRtcSessionBloc.defaultOrphanCaptureTimeout;

  setUp(() {
    factory = FakeWebRtcPeerConnectionFactory();
    signaling = FakeWebRtcSignalingGateway();
    screenCapture = FakeScreenCaptureClient();
    accessibility = FakeRemoteControlAccessibilityClient();
    timers = ManualTimers();
    bloc = WebRtcSessionBloc(
      peerConnectionFactory: factory,
      signaling: signaling,
      iceConfiguration: const WebRtcIceConfiguration.none(),
      screenCapture: screenCapture,
      remoteControl: accessibility,
      timerFactory: timers.factory,
    );
  });

  tearDown(() async => bloc.close());

  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Joined, live, ACTIVE and confirmed; peer connected; control open; screen
  /// shared. One tap proves control works before anything goes away.
  Future<(FakeWebRtcPeerConnection, FakeWebRtcDataChannel)> reachActive({
    String sdp = testSdp,
  }) async {
    bloc
      ..add(const WebRtcSignalingAvailabilityChanged(testRemoteSessionId))
      ..add(const WebRtcRemoteSessionChanged(testRemoteSessionId))
      ..add(const WebRtcActiveRemoteSessionChanged(testRemoteSessionId))
      ..add(WebRtcOfferReceived(offerFor(sdp: sdp)));
    await settle();
    final peer = factory.last;
    peer.pushConnectionState(WebRtcConnectionState.connected);
    final channel = peer.pushDataChannel();
    await settle();
    channel.pushState(WebRtcDataChannelState.open);
    await settle();
    channel.pushTap('before');
    await settle();
    expect(accessibility.taps, hasLength(1));
    expect(screenCapture.isActive, isTrue);
    return (peer, channel);
  }

  void pushHold(FakeWebRtcDataChannel channel) => channel.pushFrame(
    const WebRtcDataChannelMessage.text(
      '{"v":1,"type":"touch_hold","id":"hold-1","touch":"t-1",'
      '"x":0.41,"y":0.52}',
    ),
  );

  group('MediaProjection onStop', () {
    test(
      'withdraws control, abandons a DRAG, closes the peer and says so',
      () async {
        final (peer, channel) = await reachActive();
        pushHold(channel);
        await settle();
        accessibility.answerStart();
        await settle();
        final handle =
            (accessibility.touchCalls.single as (String, int, double, double))
                .$2;

        screenCapture.endFromPlatform();
        await settle();

        // The finger is abandoned, never released where it happened to be.
        expect(accessibility.touchCalls.last, ('abandon', handle));
        expect(
          accessibility.touchCalls
              .whereType<(String, int, int, double, double)>(),
          isEmpty,
        );
        expect(peer.isClosed, isTrue);
        expect(channel.isClosed, isTrue);
        expect(
          bloc.state,
          const WebRtcIdle(screenCapture: ScreenCaptureStatus.stoppedBySystem),
        );
        // The old channel delivers nothing any more.
        channel.pushTap('after');
        await settle();
        expect(accessibility.taps, hasLength(1));
      },
    );

    test('a new offer for the same session is not answered, and the screen '
        'is not asked for again', () async {
      await reachActive();
      screenCapture.endFromPlatform();
      await settle();

      bloc.add(WebRtcOfferReceived(offerFor(sdp: testSecondOfferSdp)));
      await settle();

      expect(factory.createCount, 1);
      expect(screenCapture.requests, [testRemoteSessionId]);
      expect(signaling.sentAnswers, hasLength(1));
    });

    test('a new assistance starts clean, with its own consent', () async {
      await reachActive();
      screenCapture.endFromPlatform();
      await settle();

      bloc
        ..add(const WebRtcActiveRemoteSessionChanged(null))
        ..add(const WebRtcRemoteSessionChanged(testOtherRemoteSessionId))
        ..add(
          const WebRtcSignalingAvailabilityChanged(testOtherRemoteSessionId),
        );
      await settle();
      expect(bloc.state, const WebRtcIdle());

      bloc.add(
        WebRtcOfferReceived(
          offerFor(remoteSessionId: testOtherRemoteSessionId),
        ),
      );
      await settle();

      expect(factory.createCount, 2);
      expect(screenCapture.requests, [
        testRemoteSessionId,
        testOtherRemoteSessionId,
      ]);
    });

    test('a stop for a capture already let go changes nothing', () async {
      await reachActive();
      bloc.add(const WebRtcScreenCaptureEndedByPlatform('another-session'));
      await settle();

      expect(bloc.state.screenCapture, ScreenCaptureStatus.active);
      expect(bloc.state.isRemoteConnectionEstablished, isTrue);
    });
  });

  group('peer connection FAILED or CLOSED', () {
    for (final ending in [
      WebRtcConnectionState.failed,
      WebRtcConnectionState.closed,
    ]) {
      test('${ending.name}: control of that peer is gone at once, and the '
          'screen only lasts the recovery window', () async {
        final (peer, channel) = await reachActive();
        pushHold(channel);
        await settle();
        accessibility.answerStart();
        await settle();

        peer.pushConnectionState(ending);
        await settle();

        expect(peer.isClosed, isTrue);
        expect(channel.isClosed, isTrue);
        expect(accessibility.touchCalls.last, isA<(String, int)>());
        // A command still arriving on the old channel reaches nothing.
        channel.pushTap('late');
        await settle();
        expect(accessibility.taps, hasLength(1));

        // The capture waits a bounded time for a new peer...
        expect(screenCapture.isActive, isTrue);
        timers.elapse(orphanTimeout - const Duration(milliseconds: 1));
        await settle();
        expect(screenCapture.isActive, isTrue);

        // ...and nobody took it.
        timers.elapse(const Duration(milliseconds: 1));
        await settle();
        expect(screenCapture.isActive, isFalse);
        expect(bloc.state.screenCapture, ScreenCaptureStatus.idle);
      });
    }

    test('a new offer within the window reuses the capture, with no new '
        'dialog, and keeps it', () async {
      final (peer, _) = await reachActive();
      peer.pushConnectionState(WebRtcConnectionState.failed);
      await settle();
      timers.elapse(orphanTimeout ~/ 2);

      bloc.add(WebRtcOfferReceived(offerFor(sdp: testSecondOfferSdp)));
      await settle();
      timers.elapse(orphanTimeout * 2);
      await settle();

      expect(factory.createCount, 2);
      expect(screenCapture.stopCount, 0);
      expect(screenCapture.isActive, isTrue);
    });

    test('after the window a new offer asks Android again', () async {
      final (peer, _) = await reachActive();
      peer.pushConnectionState(WebRtcConnectionState.closed);
      await settle();
      timers.elapse(orphanTimeout);
      await settle();

      // The real client asks for consent again once its capture was stopped;
      // the fake records the request, which is what matters here.
      bloc.add(WebRtcOfferReceived(offerFor(sdp: testSecondOfferSdp)));
      await settle();

      expect(screenCapture.requests, [
        testRemoteSessionId,
        testRemoteSessionId,
      ]);
      expect(screenCapture.stopCount, 1);
    });

    test('a closed peer is not renegotiated by the device', () async {
      final (peer, _) = await reachActive();
      peer.pushConnectionState(WebRtcConnectionState.failed);
      await settle();
      timers.elapse(orphanTimeout * 3);
      await settle();

      expect(factory.createCount, 1);
      expect(signaling.sentAnswers, hasLength(1));
    });

    test('Prompt 41: the window runs only inside the room; leaving it '
        'cancels the window and the rejoin starts it again in full', () async {
      final (peer, _) = await reachActive();
      peer.pushConnectionState(WebRtcConnectionState.failed);
      await settle();
      timers.elapse(orphanTimeout - const Duration(seconds: 1));
      await settle();

      // Out of the room: no recovery offer can reach the device, so none is
      // being waited for.
      bloc.add(const WebRtcSignalingAvailabilityChanged(null));
      await settle();
      timers.elapse(orphanTimeout * 3);
      await settle();
      expect(screenCapture.isActive, isTrue);
      expect(timers.pending, isEmpty);

      // Back in: a whole window again, and then it ends.
      bloc.add(const WebRtcSignalingAvailabilityChanged(testRemoteSessionId));
      await settle();
      timers.elapse(orphanTimeout - const Duration(milliseconds: 1));
      await settle();
      expect(screenCapture.isActive, isTrue);
      timers.elapse(const Duration(milliseconds: 1));
      await settle();
      expect(screenCapture.isActive, isFalse);
      expect(screenCapture.stopCount, 1);
    });

    test('Prompt 41: the window is long enough for the web\'s second attempt '
        'after a lost offer (30 s answer deadline + 5 s)', () {
      expect(
        orphanTimeout,
        greaterThan(const Duration(seconds: 30 + 5 + 3)),
      );
    });
  });

  group('suspended authority', () {
    test(
      'commands are refused at once and none runs after it returns',
      () async {
        final (_, channel) = await reachActive();
        pushHold(channel);
        await settle();
        accessibility.answerStart();
        await settle();

        bloc.add(const WebRtcActiveRemoteSessionChanged(null));
        await settle();
        expect(accessibility.touchCalls.last, isA<(String, int)>());

        channel.pushTap('while-suspended');
        await settle();
        expect(
          channel.sentAcks.last,
          const RemoteControlAck.failure(
            'while-suspended',
            RemoteControlError.sessionNotActive,
          ),
        );

        // Confirmed again: only commands sent from now on run.
        bloc.add(const WebRtcActiveRemoteSessionChanged(testRemoteSessionId));
        await settle();
        channel.pushTap('after');
        await settle();
        expect(accessibility.taps, hasLength(2));
        // The old touch is gone: its release reaches nothing.
        channel.pushFrame(
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
      },
    );

    test('the peer and the screen survive a suspension', () async {
      final (peer, channel) = await reachActive();
      bloc.add(const WebRtcActiveRemoteSessionChanged(null));
      await settle();
      timers.elapse(const Duration(minutes: 5));
      await settle();

      expect(peer.isClosed, isFalse);
      expect(channel.isClosed, isFalse);
      expect(screenCapture.isActive, isTrue);
    });
  });
}
