import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_inbound_message.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_message.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_device/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../../../fakes/remote_control_fakes.dart';
import '../../../fakes/remote_session_fakes.dart';
import '../../../fakes/screen_capture_fakes.dart';
import '../../../fakes/webrtc_fakes.dart';

/// A remote touch through the session gate: what may reach the finger, and
/// what ends it when the session, the channel or the peer connection does.
///
/// `accessibility.touchCalls` is what reached the port the finger lives behind.
void main() {
  late FakeWebRtcPeerConnectionFactory factory;
  late FakeRemoteControlAccessibilityClient accessibility;
  late WebRtcSessionBloc bloc;

  setUp(() {
    factory = FakeWebRtcPeerConnectionFactory();
    accessibility = FakeRemoteControlAccessibilityClient();
    bloc = WebRtcSessionBloc(
      peerConnectionFactory: factory,
      signaling: FakeWebRtcSignalingGateway(),
      iceConfiguration: const WebRtcIceConfiguration.none(),
      screenCapture: FakeScreenCaptureClient(),
      remoteControl: accessibility,
    );
  });

  tearDown(() async => bloc.close());

  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

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

  void pushHold(
    FakeWebRtcDataChannel channel, {
    String id = 'hold-7',
    String touch = 't-7',
  }) => channel.pushFrame(
    WebRtcDataChannelMessage.text(
      '{"v":1,"type":"touch_hold","id":"$id","touch":"$touch",'
      '"x":0.41,"y":0.52}',
    ),
  );

  void pushMove(FakeWebRtcDataChannel channel, int seq, {double x = 0.43}) =>
      channel.pushFrame(
        WebRtcDataChannelMessage.text(
          '{"v":1,"type":"touch_move","id":"mv-$seq","touch":"t-7",'
          '"seq":$seq,"x":$x,"y":0.55}',
        ),
      );

  void pushRelease(FakeWebRtcDataChannel channel, int seq) => channel.pushFrame(
    WebRtcDataChannelMessage.text(
      '{"v":1,"type":"touch_release","id":"rel-$seq","touch":"t-7",'
      '"seq":$seq,"x":0.6,"y":0.7}',
    ),
  );

  void pushCancel(FakeWebRtcDataChannel channel, int seq) => channel.pushFrame(
    WebRtcDataChannelMessage.text(
      '{"v":1,"type":"touch_cancel","id":"cxl-$seq","touch":"t-7",'
      '"seq":$seq}',
    ),
  );

  /// A touch held on [channel], its hold acknowledged.
  Future<void> holdOn(FakeWebRtcDataChannel channel) async {
    pushHold(channel);
    await settle();
    accessibility.answerStart();
    await settle();
    expect(channel.sentAcks, const [RemoteControlAck.success('hold-7')]);
  }

  RemoteControlAck ended(String id) =>
      RemoteControlAck.failure(id, RemoteControlError.touchEnded);

  group('the gate', () {
    test('ACTIVE, this peer, channel open: hold, moves, release', () async {
      final channel = await reachOpenChannel();
      await holdOn(channel);

      pushMove(channel, 1);
      pushMove(channel, 2, x: 0.5);
      await settle();
      pushRelease(channel, 3);
      await settle();
      accessibility.answerRelease();
      await settle();

      expect(accessibility.touchCalls, [
        ('start', 1, 0.41, 0.52),
        ('move', 1, 1, 0.43, 0.55),
        ('move', 1, 2, 0.5, 0.55),
        ('release', 1, 3, 0.6, 0.7),
      ]);
      // Two acks for four messages: the moves that were taken get none.
      expect(channel.sentAcks, const [
        RemoteControlAck.success('hold-7'),
        RemoteControlAck.success('rel-3'),
      ]);
    });

    test(
      'CONNECTING: no touch, session_not_active, for every message',
      () async {
        final channel = await reachOpenChannel(active: false);

        pushHold(channel);
        pushMove(channel, 1);
        pushRelease(channel, 2);
        pushCancel(channel, 3);
        await settle();

        expect(accessibility.touchCalls, isEmpty);
        expect(
          channel.sentAcks.map((ack) => ack.error),
          everyElement(RemoteControlError.sessionNotActive),
        );
        expect(channel.sentAcks, hasLength(4));
      },
    );

    test('a malformed touch message is answered and reaches nothing', () async {
      final channel = await reachOpenChannel();

      channel.pushFrame(
        WebRtcDataChannelMessage.text(
          '{"v":1,"type":"touch_move","id":"mv-0","touch":"t-7","seq":0,'
          '"x":0.5,"y":0.5}',
        ),
      );
      await settle();

      expect(accessibility.touchCalls, isEmpty);
      expect(channel.sentAcks, const [
        RemoteControlAck.failure('mv-0', RemoteControlError.invalidCommand),
      ]);
    });

    test(
      'a second hold is gesture_rejected and leaves the first alone',
      () async {
        final channel = await reachOpenChannel();
        await holdOn(channel);

        pushHold(channel, id: 'hold-8', touch: 't-8');
        await settle();

        expect(
          channel.sentAcks.last,
          const RemoteControlAck.failure(
            'hold-8',
            RemoteControlError.gestureRejected,
          ),
        );
        pushMove(channel, 1);
        await settle();
        expect(accessibility.touchCalls.last, ('move', 1, 1, 0.43, 0.55));
      },
    );
  });

  group('the queue', () {
    test('a tap after the hold runs only once the touch is released', () async {
      final channel = await reachOpenChannel();
      await holdOn(channel);

      channel.pushTap('tap-1');
      await settle();
      expect(accessibility.taps, isEmpty);

      pushRelease(channel, 1);
      await settle();
      expect(accessibility.taps, isEmpty);

      accessibility.answerRelease();
      await settle();
      expect(accessibility.taps, [(0.5, 0.5)]);
      expect(channel.sentAcks.last, const RemoteControlAck.success('tap-1'));
    });

    test(
      'a Home after the hold runs only once the touch is cancelled',
      () async {
        final channel = await reachOpenChannel();
        await holdOn(channel);

        channel.pushHome('home-1');
        pushCancel(channel, 1);
        await settle();
        expect(accessibility.globalActions, isEmpty);

        accessibility.answerCancel();
        await settle();
        expect(accessibility.globalActions, ['home']);
        expect(channel.sentAcks.skip(1), const [
          RemoteControlAck.success('cxl-1'),
          RemoteControlAck.success('home-1'),
        ]);
      },
    );
  });

  group('the touch ends with what it belonged to', () {
    test(
      'FINALIZAR: the finger is let go at once, and nothing queued runs',
      () async {
        final channel = await reachOpenChannel();
        await holdOn(channel);
        channel.pushHome('home-1');
        await settle();

        // What the coordinator sends the moment FINALIZAR ASISTENCIA is pressed.
        bloc.add(const WebRtcActiveRemoteSessionChanged(null));
        await settle();

        expect(accessibility.touchCalls.last, ('abandon', 1));
        expect(accessibility.globalActions, isEmpty);
        expect(
          channel.sentAcks.last,
          const RemoteControlAck.failure(
            'home-1',
            RemoteControlError.sessionNotActive,
          ),
        );

        pushMove(channel, 1);
        await settle();
        expect(
          channel.sentAcks.last,
          const RemoteControlAck.failure(
            'mv-1',
            RemoteControlError.sessionNotActive,
          ),
        );
        expect(accessibility.touchCalls.last, ('abandon', 1));
      },
    );

    test('FINALIZAR during the hold answers the hold touch_ended', () async {
      final channel = await reachOpenChannel();
      pushHold(channel);
      await settle();

      bloc.add(const WebRtcActiveRemoteSessionChanged(null));
      await settle();

      expect(accessibility.touchCalls.last, ('abandon', 1));
      expect(channel.sentAcks, [ended('hold-7')]);

      accessibility.answerStart();
      await settle();
      expect(channel.sentAcks, hasLength(1));
    });

    test('the control channel closing lets go of the finger', () async {
      final channel = await reachOpenChannel();
      await holdOn(channel);

      channel.pushState(WebRtcDataChannelState.closed);
      await settle();

      expect(accessibility.touchCalls.last, ('abandon', 1));
    });

    test('the peer connection failing lets go of the finger', () async {
      final channel = await reachOpenChannel();
      await holdOn(channel);

      factory.last.pushConnectionState(WebRtcConnectionState.failed);
      await settle();

      expect(accessibility.touchCalls.last, ('abandon', 1));
    });

    test('the session going away lets go of the finger', () async {
      final channel = await reachOpenChannel();
      await holdOn(channel);

      bloc.add(const WebRtcRemoteSessionChanged(null));
      await settle();

      expect(accessibility.touchCalls.last, ('abandon', 1));
    });

    test('closing the bloc lets go of the finger', () async {
      final channel = await reachOpenChannel();
      await holdOn(channel);

      await bloc.close();

      expect(accessibility.touchCalls.last, ('abandon', 1));
    });
  });

  group('generations', () {
    test(
      'a move from a previous generation never reaches the finger',
      () async {
        final channel = await reachOpenChannel();
        await holdOn(channel);

        bloc.add(
          const WebRtcControlMessageReceived(
            0,
            RemoteControlCommandReceived(
              RemoteTouchMoveCommand(
                id: 'stale',
                touch: 't-7',
                seq: 1,
                x: 0.9,
                y: 0.9,
              ),
            ),
          ),
        );
        bloc.add(
          const WebRtcControlMessageReceived(
            0,
            RemoteControlCommandReceived(
              RemoteTouchReleaseCommand(
                id: 'stale-release',
                touch: 't-7',
                seq: 2,
                x: 0.9,
                y: 0.9,
              ),
            ),
          ),
        );
        await settle();

        expect(accessibility.touchCalls, [('start', 1, 0.41, 0.52)]);
        expect(channel.sentAcks, hasLength(1));

        pushMove(channel, 1);
        await settle();
        expect(
          accessibility.touchCalls.last,
          ('move', 1, 1, 0.43, 0.55),
          reason: 'the stale messages did not use up its seq either',
        );
      },
    );

    test('the old channel cannot steer the touch of a new one', () async {
      final oldChannel = await reachOpenChannel();
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
      await holdOn(newChannel);

      // Same touch name, same seq, from the channel that was replaced.
      pushMove(oldChannel, 1);
      pushRelease(oldChannel, 2);
      pushCancel(oldChannel, 3);
      await settle();

      expect(accessibility.touchCalls, [('start', 1, 0.41, 0.52)]);
      expect(oldChannel.sentAcks, isEmpty);
    });
  });
}
