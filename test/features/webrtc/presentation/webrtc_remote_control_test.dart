import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_inbound_message.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_capture_result.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_message.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_device/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../../../fakes/remote_control_fakes.dart';
import '../../../fakes/remote_session_fakes.dart';
import '../../../fakes/screen_capture_fakes.dart';
import '../../../fakes/webrtc_fakes.dart';

/// Whether a frame from the `control` channel becomes a gesture.
///
/// `accessibility.taps` being empty is what "no gesture" means below: it records
/// what reached the port `dispatchGesture` lives behind.
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

  /// A negotiated peer with its control channel open. [active] says whether the
  /// backend holds the session `ACTIVE`, as the coordinator would report it.
  Future<FakeWebRtcDataChannel> reachOpenChannel({bool active = true}) async {
    bloc.add(const WebRtcSignalingAvailabilityChanged(testRemoteSessionId));
    bloc.add(const WebRtcRemoteSessionChanged(testRemoteSessionId));
    if (active) {
      bloc.add(const WebRtcActiveRemoteSessionChanged(testRemoteSessionId));
    }
    bloc.add(WebRtcOfferReceived(offerFor()));
    await settle();

    final peer = factory.last;
    peer.pushConnectionState(WebRtcConnectionState.connected);
    final channel = peer.pushDataChannel();
    await settle();
    channel.pushState(WebRtcDataChannelState.open);
    await settle();
    return channel;
  }

  group('the session gate', () {
    test('ACTIVE, this peer, channel open: the gesture runs', () async {
      final channel = await reachOpenChannel();

      channel.pushTap('t-1', x: 0.25, y: 0.75);
      await settle();

      expect(accessibility.taps, [(0.25, 0.75)]);
      expect(channel.sentAcks, const [RemoteControlAck.success('t-1')]);
    });

    test('CONNECTING: no gesture, session_not_active', () async {
      final channel = await reachOpenChannel(active: false);

      channel.pushTap('t-1');
      await settle();

      expect(accessibility.taps, isEmpty);
      expect(channel.sentAcks, const [
        RemoteControlAck.failure('t-1', RemoteControlError.sessionNotActive),
      ]);
    });

    test('ACTIVE for another session is not this session', () async {
      final channel = await reachOpenChannel(active: false);
      bloc.add(
        const WebRtcActiveRemoteSessionChanged(testOtherRemoteSessionId),
      );
      await settle();

      channel.pushTap('t-1');
      await settle();

      expect(accessibility.taps, isEmpty);
      expect(
        channel.sentAcks.single.error,
        RemoteControlError.sessionNotActive,
      );
    });

    test('a session that stopped being ACTIVE runs nothing more', () async {
      final channel = await reachOpenChannel();
      bloc.add(const WebRtcActiveRemoteSessionChanged(null));
      await settle();

      channel.pushTap('t-1');
      await settle();

      expect(accessibility.taps, isEmpty);
      expect(
        channel.sentAcks.single.error,
        RemoteControlError.sessionNotActive,
      );
    });

    test('an enabled service alone authorises nothing', () async {
      // The service is available throughout. That it stays enabled between
      // assistances is exactly why it cannot be what lets a command through.
      expect(accessibility.status, RemoteControlAccessibilityStatus.available);
      final channel = await reachOpenChannel(active: false);

      channel.pushTap('t-1');
      await settle();

      expect(accessibility.taps, isEmpty);
    });

    test('a frame on a channel that is not open runs nothing', () async {
      final channel = await reachOpenChannel();
      channel.pushState(WebRtcDataChannelState.closing);
      await settle();

      channel.pushTap('t-1');
      await settle();

      expect(accessibility.taps, isEmpty);
      expect(channel.sentAcks, isEmpty);
    });
  });

  group('frames', () {
    test('a binary frame is ignored', () async {
      final channel = await reachOpenChannel();

      channel.pushFrame(
        WebRtcDataChannelMessage.binary(Uint8List.fromList([1, 2, 3])),
      );
      await settle();

      expect(accessibility.taps, isEmpty);
      expect(channel.sentAcks, isEmpty);
    });

    test('a frame with no id is ignored', () async {
      final channel = await reachOpenChannel();

      channel.pushFrame(const WebRtcDataChannelMessage.text('{not json'));
      channel.pushFrame(
        const WebRtcDataChannelMessage.text(
          '{"v":1,"type":"tap","x":0.5,"y":0.5}',
        ),
      );
      await settle();

      expect(accessibility.taps, isEmpty);
      expect(channel.sentAcks, isEmpty);
    });

    test('a malformed tap is answered and never runs', () async {
      final channel = await reachOpenChannel();

      channel.pushFrame(
        const WebRtcDataChannelMessage.text(
          '{"v":1,"type":"tap","id":"t-1","x":1.1,"y":0.5}',
        ),
      );
      await settle();

      expect(accessibility.taps, isEmpty);
      expect(channel.sentAcks, const [
        RemoteControlAck.failure('t-1', RemoteControlError.invalidCommand),
      ]);
    });

    test('a command from the future is answered and never runs', () async {
      final channel = await reachOpenChannel();

      channel.pushFrame(
        const WebRtcDataChannelMessage.text(
          '{"v":2,"type":"tap","id":"t-1","x":0.5,"y":0.5}',
        ),
      );
      await settle();

      expect(accessibility.taps, isEmpty);
      expect(channel.sentAcks, const [
        RemoteControlAck.failure('t-1', RemoteControlError.unsupportedCommand),
      ]);
    });
  });

  group('outcomes reach the ack', () {
    test('a rejected gesture', () async {
      final channel = await reachOpenChannel();
      accessibility.outcome = RemoteGestureOutcome.rejected;

      channel.pushTap('t-1');
      await settle();

      expect(channel.sentAcks, const [
        RemoteControlAck.failure('t-1', RemoteControlError.gestureRejected),
      ]);
    });

    test('a service that is gone, without a crash', () async {
      final channel = await reachOpenChannel();
      accessibility.outcome = RemoteGestureOutcome.unavailable;

      channel.pushTap('t-1');
      await settle();

      expect(channel.sentAcks, const [
        RemoteControlAck.failure(
          't-1',
          RemoteControlError.accessibilityUnavailable,
        ),
      ]);
    });

    test('nothing is acknowledged before Android answers', () async {
      final channel = await reachOpenChannel();
      accessibility.holdGestures = true;

      channel.pushTap('t-1');
      await settle();

      expect(accessibility.taps, hasLength(1));
      expect(channel.sentAcks, isEmpty);

      accessibility.finishGesture();
      await settle();

      expect(channel.sentAcks, const [RemoteControlAck.success('t-1')]);
    });
  });

  group('generations', () {
    test('a message from a previous generation never runs', () async {
      final channel = await reachOpenChannel();

      // Generation 0 is long gone: this negotiation is generation 1.
      bloc.add(
        const WebRtcControlMessageReceived(
          0,
          RemoteControlCommandReceived(
            RemoteTapCommand(id: 'stale', x: 0.5, y: 0.5),
          ),
        ),
      );
      await settle();

      expect(accessibility.taps, isEmpty);
      expect(channel.sentAcks, isEmpty);
    });

    test('the channel of a replaced peer delivers nothing', () async {
      final oldChannel = await reachOpenChannel();
      final oldPeer = factory.last;

      oldPeer.pushConnectionState(WebRtcConnectionState.failed);
      await settle();
      bloc.add(WebRtcOfferReceived(offerFor(sdp: testSecondOfferSdp)));
      await settle();
      expect(factory.createCount, 2);

      oldChannel.pushTap('stale');
      await settle();

      expect(accessibility.taps, isEmpty);
      expect(oldChannel.sentAcks, isEmpty);
    });

    test('a tap queued before the peer failed never runs', () async {
      final channel = await reachOpenChannel();
      accessibility.holdGestures = true;
      channel.pushTap('running');
      channel.pushTap('queued');
      await settle();
      expect(accessibility.taps, hasLength(1));

      factory.last.pushConnectionState(WebRtcConnectionState.failed);
      await settle();
      accessibility.finishGesture();
      await settle();

      expect(accessibility.taps, hasLength(1));
      expect(channel.sentAcks, isEmpty);
    });

    test(
      'an ack does not cross to the channel that replaced its own',
      () async {
        final oldChannel = await reachOpenChannel();
        accessibility.holdGestures = true;
        oldChannel.pushTap('running');
        await settle();

        factory.last.pushConnectionState(WebRtcConnectionState.failed);
        await settle();
        bloc.add(WebRtcOfferReceived(offerFor(sdp: testSecondOfferSdp)));
        await settle();
        final peer = factory.last;
        peer.pushConnectionState(WebRtcConnectionState.connected);
        final newChannel = peer.pushDataChannel();
        await settle();
        newChannel.pushState(WebRtcDataChannelState.open);
        await settle();

        accessibility.finishGesture();
        await settle();

        expect(oldChannel.sentAcks, isEmpty);
        expect(newChannel.sentAcks, isEmpty);
      },
    );
  });

  group('a swipe', () {
    test('ACTIVE, this peer, channel open: the gesture runs', () async {
      final channel = await reachOpenChannel();

      channel.pushSwipe(
        's-1',
        startX: 0.2,
        startY: 0.8,
        endX: 0.2,
        endY: 0.3,
        durationMs: 350,
      );
      await settle();

      expect(accessibility.swipes, [(0.2, 0.8, 0.2, 0.3, 350)]);
      expect(accessibility.taps, isEmpty);
      expect(channel.sentAcks, const [RemoteControlAck.success('s-1')]);
    });

    test('CONNECTING: no gesture, session_not_active', () async {
      final channel = await reachOpenChannel(active: false);

      channel.pushSwipe('s-1');
      await settle();

      expect(accessibility.gestures, isEmpty);
      expect(channel.sentAcks, const [
        RemoteControlAck.failure('s-1', RemoteControlError.sessionNotActive),
      ]);
    });

    test('ACTIVE for another session is not this session', () async {
      final channel = await reachOpenChannel(active: false);
      bloc.add(
        const WebRtcActiveRemoteSessionChanged(testOtherRemoteSessionId),
      );
      await settle();

      channel.pushSwipe('s-1');
      await settle();

      expect(accessibility.gestures, isEmpty);
      expect(
        channel.sentAcks.single.error,
        RemoteControlError.sessionNotActive,
      );
    });

    test('a session that stopped being ACTIVE runs nothing more', () async {
      final channel = await reachOpenChannel();
      bloc.add(const WebRtcActiveRemoteSessionChanged(null));
      await settle();

      channel.pushSwipe('s-1');
      await settle();

      expect(accessibility.gestures, isEmpty);
      expect(
        channel.sentAcks.single.error,
        RemoteControlError.sessionNotActive,
      );
    });

    test('on a channel that is not open it runs nothing', () async {
      final channel = await reachOpenChannel();
      channel.pushState(WebRtcDataChannelState.closing);
      await settle();

      channel.pushSwipe('s-1');
      await settle();

      expect(accessibility.gestures, isEmpty);
      expect(channel.sentAcks, isEmpty);
    });

    test('a malformed one is answered and never runs', () async {
      final channel = await reachOpenChannel();

      channel.pushSwipe('short', durationMs: 49);
      channel.pushSwipe(
        'nowhere',
        startX: 0.5,
        startY: 0.5,
        endX: 0.5,
        endY: 0.5,
      );
      await settle();

      expect(accessibility.gestures, isEmpty);
      expect(channel.sentAcks, const [
        RemoteControlAck.failure('short', RemoteControlError.invalidCommand),
        RemoteControlAck.failure('nowhere', RemoteControlError.invalidCommand),
      ]);
    });

    test('a refused gesture is gesture_rejected', () async {
      final channel = await reachOpenChannel();
      accessibility.outcome = RemoteGestureOutcome.rejected;

      channel.pushSwipe('s-1');
      await settle();

      expect(channel.sentAcks, const [
        RemoteControlAck.failure('s-1', RemoteControlError.gestureRejected),
      ]);
    });

    test('a service that is gone is accessibility_unavailable', () async {
      final channel = await reachOpenChannel();
      accessibility.outcome = RemoteGestureOutcome.unavailable;

      channel.pushSwipe('s-1');
      await settle();

      expect(channel.sentAcks, const [
        RemoteControlAck.failure(
          's-1',
          RemoteControlError.accessibilityUnavailable,
        ),
      ]);
    });

    test('nothing is acknowledged before Android answers', () async {
      final channel = await reachOpenChannel();
      accessibility.holdGestures = true;

      channel.pushSwipe('s-1');
      await settle();

      expect(accessibility.swipes, hasLength(1));
      expect(channel.sentAcks, isEmpty);

      accessibility.finishGesture();
      await settle();

      expect(channel.sentAcks, const [RemoteControlAck.success('s-1')]);
    });

    group('generations', () {
      test('a message from a previous generation never runs', () async {
        final channel = await reachOpenChannel();

        bloc.add(
          const WebRtcControlMessageReceived(
            0,
            RemoteControlCommandReceived(
              RemoteSwipeCommand(
                id: 'stale',
                startX: 0.5,
                startY: 0.8,
                endX: 0.5,
                endY: 0.2,
                durationMs: 300,
              ),
            ),
          ),
        );
        await settle();

        expect(accessibility.gestures, isEmpty);
        expect(channel.sentAcks, isEmpty);
      });

      test('the channel of a replaced peer delivers nothing', () async {
        final oldChannel = await reachOpenChannel();

        factory.last.pushConnectionState(WebRtcConnectionState.failed);
        await settle();
        bloc.add(WebRtcOfferReceived(offerFor(sdp: testSecondOfferSdp)));
        await settle();
        expect(factory.createCount, 2);

        oldChannel.pushSwipe('stale');
        await settle();

        expect(accessibility.gestures, isEmpty);
        expect(oldChannel.sentAcks, isEmpty);
      });

      test('a swipe queued before the peer failed never runs', () async {
        final channel = await reachOpenChannel();
        accessibility.holdGestures = true;
        channel.pushTap('running');
        channel.pushSwipe('queued');
        await settle();

        factory.last.pushConnectionState(WebRtcConnectionState.failed);
        await settle();
        accessibility.finishGesture();
        await settle();

        expect(accessibility.swipes, isEmpty);
        expect(channel.sentAcks, isEmpty);
      });
    });
  });

  for (final type in const ['back', 'home', 'recents']) {
    void push(FakeWebRtcDataChannel channel, String id) => switch (type) {
      'back' => channel.pushBack(id),
      'home' => channel.pushHome(id),
      _ => channel.pushRecents(id),
    };

    group('a $type', () {
      test('ACTIVE, this peer, channel open: the action runs', () async {
        final channel = await reachOpenChannel();

        push(channel, 'n-1');
        await settle();

        expect(accessibility.globalActions, [type]);
        expect(accessibility.taps, isEmpty);
        expect(accessibility.swipes, isEmpty);
        expect(channel.sentAcks, const [RemoteControlAck.success('n-1')]);
      });

      test('CONNECTING: no action, session_not_active', () async {
        final channel = await reachOpenChannel(active: false);

        push(channel, 'n-1');
        await settle();

        expect(accessibility.gestures, isEmpty);
        expect(channel.sentAcks, const [
          RemoteControlAck.failure('n-1', RemoteControlError.sessionNotActive),
        ]);
      });

      test('an enabled service alone authorises nothing', () async {
        expect(
          accessibility.status,
          RemoteControlAccessibilityStatus.available,
        );
        final channel = await reachOpenChannel(active: false);

        push(channel, 'n-1');
        await settle();

        expect(accessibility.gestures, isEmpty);
      });

      test('ACTIVE for another session is not this session', () async {
        final channel = await reachOpenChannel(active: false);
        bloc.add(
          const WebRtcActiveRemoteSessionChanged(testOtherRemoteSessionId),
        );
        await settle();

        push(channel, 'n-1');
        await settle();

        expect(accessibility.gestures, isEmpty);
        expect(
          channel.sentAcks.single.error,
          RemoteControlError.sessionNotActive,
        );
      });

      test('arriving after the session closed runs nothing', () async {
        final channel = await reachOpenChannel();
        bloc.add(const WebRtcActiveRemoteSessionChanged(null));
        await settle();

        push(channel, 'late');
        await settle();

        expect(accessibility.gestures, isEmpty);
        expect(channel.sentAcks, const [
          RemoteControlAck.failure('late', RemoteControlError.sessionNotActive),
        ]);
      });

      test('on a channel that is not open it runs nothing', () async {
        final channel = await reachOpenChannel();
        channel.pushState(WebRtcDataChannelState.closing);
        await settle();

        push(channel, 'n-1');
        await settle();

        expect(accessibility.gestures, isEmpty);
        expect(channel.sentAcks, isEmpty);
      });

      test('a refused action is gesture_rejected', () async {
        final channel = await reachOpenChannel();
        accessibility.outcome = RemoteGestureOutcome.rejected;

        push(channel, 'n-1');
        await settle();

        expect(channel.sentAcks, const [
          RemoteControlAck.failure('n-1', RemoteControlError.gestureRejected),
        ]);
      });

      test('a service that is gone is accessibility_unavailable', () async {
        final channel = await reachOpenChannel();
        accessibility.outcome = RemoteGestureOutcome.unavailable;

        push(channel, 'n-1');
        await settle();

        expect(channel.sentAcks, const [
          RemoteControlAck.failure(
            'n-1',
            RemoteControlError.accessibilityUnavailable,
          ),
        ]);
      });

      test('nothing is acknowledged before Android answers', () async {
        final channel = await reachOpenChannel();
        accessibility.holdGestures = true;

        push(channel, 'n-1');
        await settle();

        expect(accessibility.globalActions, hasLength(1));
        expect(channel.sentAcks, isEmpty);

        accessibility.finishGesture();
        await settle();

        expect(channel.sentAcks, const [RemoteControlAck.success('n-1')]);
      });

      test('the session ending drops it before it starts', () async {
        final channel = await reachOpenChannel();
        accessibility.holdGestures = true;
        channel.pushSwipe('a');
        push(channel, 'b');
        await settle();

        bloc.add(const WebRtcActiveRemoteSessionChanged(null));
        await settle();
        accessibility.finishGesture();
        await settle();

        expect(accessibility.swipes, hasLength(1));
        expect(accessibility.globalActions, isEmpty);
        expect(channel.sentAcks, const [
          RemoteControlAck.failure('b', RemoteControlError.sessionNotActive),
          RemoteControlAck.success('a'),
        ]);
      });

      test('does not need the screen to be shared', () async {
        // No MediaProjection. The video is the web's concern, and an action
        // that names no position has no use for it.
        screenCapture.result = const ScreenCaptureUnavailable(
          ScreenCaptureFailure.captureRefused,
        );
        final channel = await reachOpenChannel();
        expect(screenCapture.isActive, isFalse);

        push(channel, 'n-1');
        await settle();

        expect(accessibility.globalActions, [type]);
        expect(channel.sentAcks, const [RemoteControlAck.success('n-1')]);
      });

      group('generations', () {
        test('a message from a previous generation never runs', () async {
          final channel = await reachOpenChannel();

          bloc.add(
            WebRtcControlMessageReceived(
              0,
              RemoteControlCommandReceived(switch (type) {
                'back' => const RemoteBackCommand(id: 'stale'),
                'home' => const RemoteHomeCommand(id: 'stale'),
                _ => const RemoteRecentsCommand(id: 'stale'),
              }),
            ),
          );
          await settle();

          expect(accessibility.gestures, isEmpty);
          expect(channel.sentAcks, isEmpty);
        });

        test('the channel of a replaced peer delivers nothing', () async {
          final oldChannel = await reachOpenChannel();

          factory.last.pushConnectionState(WebRtcConnectionState.failed);
          await settle();
          bloc.add(WebRtcOfferReceived(offerFor(sdp: testSecondOfferSdp)));
          await settle();
          expect(factory.createCount, 2);

          push(oldChannel, 'stale');
          await settle();

          expect(accessibility.gestures, isEmpty);
          expect(oldChannel.sentAcks, isEmpty);
        });

        test('one queued before the peer failed never runs', () async {
          final channel = await reachOpenChannel();
          accessibility.holdGestures = true;
          channel.pushTap('running');
          push(channel, 'queued');
          await settle();

          factory.last.pushConnectionState(WebRtcConnectionState.failed);
          await settle();
          accessibility.finishGesture();
          await settle();

          expect(accessibility.globalActions, isEmpty);
          expect(channel.sentAcks, isEmpty);
        });
      });
    });
  }

  group('a closed channel', () {
    test('gets no late ack', () async {
      final channel = await reachOpenChannel();
      accessibility.holdGestures = true;
      channel.pushTap('t-1');
      await settle();

      channel.pushState(WebRtcDataChannelState.closed);
      await settle();
      accessibility.finishGesture();
      await settle();

      expect(channel.sentAcks, isEmpty);
    });
  });

  group('the queue', () {
    test('one gesture at a time, in order', () async {
      final channel = await reachOpenChannel();
      accessibility.holdGestures = true;

      channel.pushTap('a', x: 0.1);
      channel.pushTap('b', x: 0.2);
      await settle();

      // A has started and B is waiting for it.
      expect(accessibility.taps, [(0.1, 0.5)]);
      expect(channel.sentAcks, isEmpty);

      accessibility.finishGesture();
      await settle();

      // A is answered, and only then B starts.
      expect(accessibility.taps, [(0.1, 0.5), (0.2, 0.5)]);
      expect(channel.sentAcks, const [RemoteControlAck.success('a')]);

      accessibility.finishGesture();
      await settle();

      expect(channel.sentAcks, const [
        RemoteControlAck.success('a'),
        RemoteControlAck.success('b'),
      ]);
    });

    test('the session ending drops what has not started', () async {
      final channel = await reachOpenChannel();
      accessibility.holdGestures = true;
      channel.pushTap('a');
      channel.pushTap('b');
      await settle();

      bloc.add(const WebRtcActiveRemoteSessionChanged(null));
      await settle();

      // A cannot be recalled, and is left to finish.
      accessibility.finishGesture();
      await settle();

      // B never ran, and the web was told so while the channel could say it.
      expect(accessibility.taps, hasLength(1));
      expect(channel.sentAcks, const [
        RemoteControlAck.failure('b', RemoteControlError.sessionNotActive),
        RemoteControlAck.success('a'),
      ]);
    });

    test('tap, swipe, tap run one at a time through one queue', () async {
      final channel = await reachOpenChannel();
      accessibility.holdGestures = true;

      channel.pushTap('a', x: 0.1);
      channel.pushSwipe('b');
      channel.pushTap('c', x: 0.9);
      await settle();
      expect(accessibility.gestures, [(0.1, 0.5)]);
      expect(channel.sentAcks, isEmpty);

      accessibility.finishGesture();
      await settle();
      expect(accessibility.gestures, [(0.1, 0.5), (0.5, 0.8, 0.5, 0.2, 300)]);
      expect(channel.sentAcks, const [RemoteControlAck.success('a')]);

      accessibility.finishGesture();
      await settle();
      expect(accessibility.gestures, [
        (0.1, 0.5),
        (0.5, 0.8, 0.5, 0.2, 300),
        (0.9, 0.5),
      ]);

      accessibility.finishGesture();
      await settle();
      expect(channel.sentAcks, const [
        RemoteControlAck.success('a'),
        RemoteControlAck.success('b'),
        RemoteControlAck.success('c'),
      ]);
    });

    test('tap, swipe, back, home, recents, tap run in order', () async {
      final channel = await reachOpenChannel();
      accessibility.holdGestures = true;

      channel.pushTap('a', x: 0.1);
      channel.pushSwipe('b');
      channel.pushBack('c');
      channel.pushHome('d');
      channel.pushRecents('e');
      channel.pushTap('f', x: 0.9);
      await settle();
      expect(accessibility.gestures, [(0.1, 0.5)]);

      final expected = <Object>[
        (0.1, 0.5),
        (0.5, 0.8, 0.5, 0.2, 300),
        'back',
        'home',
        'recents',
        (0.9, 0.5),
      ];
      for (var finished = 1; finished < expected.length; finished++) {
        accessibility.finishGesture();
        await settle();
        expect(accessibility.gestures, expected.take(finished + 1));
        expect(channel.sentAcks, hasLength(finished));
      }

      accessibility.finishGesture();
      await settle();
      expect(channel.sentAcks, const [
        RemoteControlAck.success('a'),
        RemoteControlAck.success('b'),
        RemoteControlAck.success('c'),
        RemoteControlAck.success('d'),
        RemoteControlAck.success('e'),
        RemoteControlAck.success('f'),
      ]);
    });

    test('the session ending drops a swipe that has not started', () async {
      final channel = await reachOpenChannel();
      accessibility.holdGestures = true;
      channel.pushTap('a');
      channel.pushSwipe('b');
      await settle();

      bloc.add(const WebRtcActiveRemoteSessionChanged(null));
      await settle();
      accessibility.finishGesture();
      await settle();

      expect(accessibility.taps, hasLength(1));
      expect(accessibility.swipes, isEmpty);
      expect(channel.sentAcks, const [
        RemoteControlAck.failure('b', RemoteControlError.sessionNotActive),
        RemoteControlAck.success('a'),
      ]);
    });

    test('a running swipe is left to finish when the session ends', () async {
      final channel = await reachOpenChannel();
      accessibility.holdGestures = true;
      channel.pushSwipe('a');
      channel.pushSwipe('b');
      await settle();

      bloc.add(const WebRtcActiveRemoteSessionChanged(null));
      await settle();
      accessibility.finishGesture();
      await settle();

      expect(accessibility.swipes, hasLength(1));
      expect(channel.sentAcks, const [
        RemoteControlAck.failure('b', RemoteControlError.sessionNotActive),
        RemoteControlAck.success('a'),
      ]);
    });

    test('the next authorised tap runs after a dropped queue', () async {
      final channel = await reachOpenChannel();
      accessibility.holdGestures = true;
      channel.pushTap('a');
      channel.pushTap('b');
      await settle();
      bloc.add(const WebRtcActiveRemoteSessionChanged(null));
      await settle();
      accessibility.finishGesture();
      await settle();

      accessibility.holdGestures = false;
      bloc.add(const WebRtcActiveRemoteSessionChanged(testRemoteSessionId));
      await settle();
      channel.pushTap('c');
      await settle();

      expect(accessibility.taps, hasLength(2));
      expect(channel.sentAcks.last, const RemoteControlAck.success('c'));
    });
  });
}
