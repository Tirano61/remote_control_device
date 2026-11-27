import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_device/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../../../fakes/remote_control_fakes.dart';
import '../../../fakes/remote_session_fakes.dart';
import '../../../fakes/screen_capture_fakes.dart';
import '../../../fakes/webrtc_fakes.dart';

/// A2 of the Prompt 44 audit: the native control gate follows the C2
/// authority, and a gesture running when that authority goes is never
/// reported done.
///
/// `accessibility.controlCalls` is what reached the Android side's gate, in
/// order; `accessibility.openGrant` is what it holds open.
void main() {
  late FakeWebRtcPeerConnectionFactory factory;
  late FakeRemoteControlAccessibilityClient accessibility;
  late FakeScreenCaptureClient screenCapture;
  late WebRtcSessionBloc bloc;

  setUp(() {
    factory = FakeWebRtcPeerConnectionFactory();
    accessibility = FakeRemoteControlAccessibilityClient();
    screenCapture = FakeScreenCaptureClient();
    bloc = WebRtcSessionBloc(
      peerConnectionFactory: factory,
      signaling: FakeWebRtcSignalingGateway(),
      iceConfiguration: const WebRtcIceConfiguration.none(),
      screenCapture: screenCapture,
      remoteControl: accessibility,
    );
  });

  tearDown(() async => bloc.close());

  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<FakeWebRtcDataChannel> openChannelOn(
    FakeWebRtcPeerConnection peer,
  ) async {
    peer.pushConnectionState(WebRtcConnectionState.connected);
    final channel = peer.pushDataChannel();
    await settle();
    channel.pushState(WebRtcDataChannelState.open);
    await settle();
    return channel;
  }

  Future<FakeWebRtcDataChannel> reachOpenChannel({bool active = true}) async {
    bloc.add(const WebRtcSignalingAvailabilityChanged(testRemoteSessionId));
    bloc.add(const WebRtcRemoteSessionChanged(testRemoteSessionId));
    bloc.add(const WebRtcRemoteSessionAuthorityChanged(testRemoteSessionId));
    if (active) {
      bloc.add(const WebRtcActiveRemoteSessionChanged(testRemoteSessionId));
    }
    bloc.add(WebRtcOfferReceived(offerFor()));
    await settle();
    return openChannelOn(factory.last);
  }

  void suspend() => bloc.add(const WebRtcActiveRemoteSessionChanged(null));

  void confirmAgain() =>
      bloc.add(const WebRtcActiveRemoteSessionChanged(testRemoteSessionId));

  /// FINALIZAR, as the coordinator forwards it: control first, then the
  /// session, naming the one that is over.
  void finalizar() {
    bloc.add(const WebRtcActiveRemoteSessionChanged(null));
    bloc.add(const WebRtcRemoteSessionAuthorityChanged(null));
    bloc.add(
      const WebRtcRemoteSessionChanged(
        null,
        endedRemoteSessionId: testRemoteSessionId,
      ),
    );
  }

  group('opening', () {
    test(
      'control authorised on a peer opens grant 1 for that session',
      () async {
        await reachOpenChannel();

        expect(accessibility.controlCalls, [('open', 1, testRemoteSessionId)]);
        expect(accessibility.openGrant, 1);
      },
    );

    test('CONNECTING opens nothing', () async {
      await reachOpenChannel(active: false);

      expect(accessibility.controlCalls, isEmpty);
    });

    test(
      'ACTIVE with no peer opens nothing: commands only come on a channel',
      () async {
        bloc.add(const WebRtcRemoteSessionChanged(testRemoteSessionId));
        confirmAgain();
        await settle();

        expect(accessibility.controlCalls, isEmpty);
      },
    );

    test('a re-confirmation opens a new grant, never the old one', () async {
      await reachOpenChannel();
      suspend();
      await settle();
      confirmAgain();
      await settle();

      expect(accessibility.openedGrants, [1, 2]);
      expect(accessibility.openGrant, 2);
    });

    test('a gate the Android side would not open keeps refusing, and is not '
        'retried by anything but the authority', () async {
      accessibility.openOutcome = RemoteControlOpenOutcome.ended;
      await reachOpenChannel();

      expect(accessibility.controlOpen, isFalse);
      expect(accessibility.openedGrants, [1]);
    });
  });

  group('closing', () {
    test('a suspension closes the gate at once, before anything else is '
        'awaited', () async {
      await reachOpenChannel();

      suspend();
      await settle();

      expect(accessibility.controlCalls.last, ('close', null));
      expect(accessibility.controlOpen, isFalse);
    });

    test('A2: a swipe running when the authority is suspended is not '
        'reported ok, even if Android completes it', () async {
      final channel = await reachOpenChannel();
      accessibility.holdGestures = true;
      channel.pushSwipe('swipe-1');
      await settle();
      expect(accessibility.swipes, hasLength(1));

      suspend();
      await settle();
      accessibility.finishGesture(RemoteGestureOutcome.completed);
      await settle();

      expect(channel.sentAcks, const [
        RemoteControlAck.failure(
          'swipe-1',
          RemoteControlError.sessionNotActive,
        ),
      ]);
    });

    test(
      'a long press running when the authority goes is not reported ok',
      () async {
        final channel = await reachOpenChannel();
        accessibility.holdGestures = true;
        channel.pushLongPress('lp-1');
        await settle();

        suspend();
        await settle();
        accessibility.finishGesture(RemoteGestureOutcome.revoked);
        await settle();

        expect(channel.sentAcks, const [
          RemoteControlAck.failure('lp-1', RemoteControlError.sessionNotActive),
        ]);
      },
    );

    test('a tap that finished before the suspension stays ok', () async {
      final channel = await reachOpenChannel();
      channel.pushTap('tap-1');
      await settle();

      suspend();
      await settle();

      expect(channel.sentAcks, const [RemoteControlAck.success('tap-1')]);
    });

    test(
      'a tap still queued when the authority goes never reaches Android',
      () async {
        final channel = await reachOpenChannel();
        accessibility.holdGestures = true;
        channel.pushSwipe('a');
        channel.pushTap('b');
        await settle();

        suspend();
        await settle();
        accessibility.finishGesture();
        await settle();

        expect(accessibility.taps, isEmpty);
        expect(channel.sentAcks.map((ack) => (ack.id, ack.ok)), [
          ('b', false),
          ('a', false),
        ]);
      },
    );

    test(
      'a command after the suspension is refused here and never sent',
      () async {
        final channel = await reachOpenChannel();
        suspend();
        await settle();

        channel.pushTap('t-late');
        await settle();

        expect(accessibility.taps, isEmpty);
        expect(
          channel.sentAcks.single.error,
          RemoteControlError.sessionNotActive,
        );
      },
    );

    test(
      'FINALIZAR closes the gate and records the session as ended there',
      () async {
        await reachOpenChannel();

        finalizar();
        await settle();

        expect(accessibility.controlCalls, [
          ('open', 1, testRemoteSessionId),
          ('close', null),
          ('close', testRemoteSessionId),
        ]);
        expect(accessibility.controlOpen, isFalse);
      },
    );

    test('FINALIZAR during a swipe: the swipe is not reported done, and no '
        'command runs afterwards', () async {
      final channel = await reachOpenChannel();
      accessibility.holdGestures = true;
      channel.pushSwipe('swipe-1');
      await settle();

      finalizar();
      await settle();
      accessibility.finishGesture(RemoteGestureOutcome.completed);
      await settle();
      channel.pushTap('after');
      await settle();

      expect(accessibility.taps, isEmpty);
      expect(accessibility.swipes, hasLength(1));
      // The channel was closed with the peer; nothing about either reports ok.
      expect(channel.sentAcks.where((ack) => ack.ok), isEmpty);
    });

    test('a session closed by the backend (SYSTEM or TECHNICIAN) is recorded '
        'ended in the same way', () async {
      await reachOpenChannel();

      bloc.add(const WebRtcActiveRemoteSessionChanged(null));
      bloc.add(
        const WebRtcRemoteSessionChanged(
          null,
          endedRemoteSessionId: testRemoteSessionId,
        ),
      );
      await settle();

      expect(accessibility.controlCalls.last, ('close', testRemoteSessionId));
    });

    test(
      'a reset (no session, nothing ended) closes without recording an end',
      () async {
        await reachOpenChannel();

        bloc.add(const WebRtcActiveRemoteSessionChanged(null));
        bloc.add(const WebRtcRemoteSessionChanged(null));
        await settle();

        expect(
          accessibility.controlCalls.where(
            (call) => call == ('close', testRemoteSessionId),
          ),
          isEmpty,
        );
        expect(accessibility.controlOpen, isFalse);
      },
    );

    test('Android taking the screen away closes the gate', () async {
      await reachOpenChannel();
      expect(screenCapture.isActive, isTrue);

      screenCapture.endFromPlatform();
      await settle();

      expect(accessibility.controlCalls.last, ('close', null));
      expect(accessibility.controlOpen, isFalse);
    });

    test('closing the bloc closes the gate', () async {
      await reachOpenChannel();

      await bloc.close();

      expect(accessibility.controlOpen, isFalse);
    });
  });

  group('generations', () {
    test('a recovery offer closes the old grant before the new peer, and '
        'opens a new one for it', () async {
      final oldChannel = await reachOpenChannel();
      accessibility.holdGestures = true;
      oldChannel.pushSwipe('old-swipe');
      await settle();

      bloc.add(WebRtcOfferReceived(offerFor(sdp: testSecondOfferSdp)));
      await settle();
      accessibility.finishGesture(RemoteGestureOutcome.completed);
      await settle();
      accessibility.holdGestures = false;
      final channel = await openChannelOn(factory.last);
      channel.pushTap('new-tap');
      await settle();

      expect(accessibility.controlCalls, [
        ('open', 1, testRemoteSessionId),
        ('close', null),
        ('open', 2, testRemoteSessionId),
      ]);
      expect(oldChannel.sentAcks.where((ack) => ack.ok), isEmpty);
      expect(channel.sentAcks, const [RemoteControlAck.success('new-tap')]);
    });

    test('a peer that failed and was torn down closes the gate', () async {
      await reachOpenChannel();

      factory.last.pushConnectionState(WebRtcConnectionState.failed);
      await settle();

      expect(accessibility.controlOpen, isFalse);
    });
  });
}
