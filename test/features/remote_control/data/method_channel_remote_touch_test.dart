import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/remote_control/data/method_channel_remote_control_accessibility_client.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';

/// The remote touch half of the bridge, against a mock of the Android half.
/// The method and argument names are the contract with
/// `RemoteControlAccessibilityChannel.kt`, so they are spelled out here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('remote_control/accessibility');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late MethodChannelRemoteControlAccessibilityClient client;
  late List<MethodCall> calls;

  void answerWith(Object? Function(MethodCall call) answer) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer(call);
    });
  }

  setUp(() {
    client = MethodChannelRemoteControlAccessibilityClient(
      gestureTimeout: const Duration(milliseconds: 20),
    );
    calls = [];
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('startRemoteTouch', () {
    test('sends the handle and the position, and nothing else', () async {
      answerWith((_) => 'held');

      await client.startTouch(touch: 3, x: 0.41, y: 0.52);

      expect(calls.single.method, 'startRemoteTouch');
      expect(calls.single.arguments, {'touch': 3, 'x': 0.41, 'y': 0.52});
    });

    for (final (wire, outcome) in const [
      ('held', RemoteTouchStartOutcome.held),
      ('ended', RemoteTouchStartOutcome.ended),
      ('unsupported', RemoteTouchStartOutcome.unsupported),
      ('unavailable', RemoteTouchStartOutcome.unavailable),
      ('rejected', RemoteTouchStartOutcome.rejected),
      ('busy', RemoteTouchStartOutcome.rejected),
      ('invalid', RemoteTouchStartOutcome.rejected),
      ('something new', RemoteTouchStartOutcome.rejected),
    ]) {
      test('"$wire" is ${outcome.name}', () async {
        answerWith((_) => wire);

        expect(await client.startTouch(touch: 1, x: 0, y: 0), outcome);
      });
    }

    test('a bridge that is not there is unavailable', () async {
      expect(
        await client.startTouch(touch: 1, x: 0, y: 0),
        RemoteTouchStartOutcome.unavailable,
      );
    });

    test('a bridge that never answers is a refusal', () async {
      final never = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => never.future);

      expect(
        await client.startTouch(touch: 1, x: 0, y: 0),
        RemoteTouchStartOutcome.rejected,
      );
    });
  });

  group('moveRemoteTouch', () {
    test('sends the handle, the seq and the position', () async {
      answerWith((_) => 'accepted');

      await client.moveTouch(touch: 3, seq: 12, x: 0.43, y: 0.55);

      expect(calls.single.method, 'moveRemoteTouch');
      expect(calls.single.arguments, {
        'touch': 3,
        'seq': 12,
        'x': 0.43,
        'y': 0.55,
      });
    });

    for (final (wire, outcome) in const [
      ('accepted', RemoteTouchMoveOutcome.accepted),
      ('unavailable', RemoteTouchMoveOutcome.unavailable),
      ('ended', RemoteTouchMoveOutcome.ended),
      ('invalid', RemoteTouchMoveOutcome.ended),
      ('something new', RemoteTouchMoveOutcome.ended),
    ]) {
      test('"$wire" is ${outcome.name}', () async {
        answerWith((_) => wire);

        expect(await client.moveTouch(touch: 1, seq: 1, x: 0, y: 0), outcome);
      });
    }

    test('a bridge that is not there is unavailable', () async {
      expect(
        await client.moveTouch(touch: 1, seq: 1, x: 0, y: 0),
        RemoteTouchMoveOutcome.unavailable,
      );
    });

    test('a bridge that throws ends the touch', () async {
      answerWith((_) => throw PlatformException(code: 'BOOM'));

      expect(
        await client.moveTouch(touch: 1, seq: 1, x: 0, y: 0),
        RemoteTouchMoveOutcome.ended,
      );
    });
  });

  group('releaseRemoteTouch', () {
    test('sends the handle, the seq and the position', () async {
      answerWith((_) => 'completed');

      await client.releaseTouch(touch: 3, seq: 40, x: 0.6, y: 0.7);

      expect(calls.single.method, 'releaseRemoteTouch');
      expect(calls.single.arguments, {
        'touch': 3,
        'seq': 40,
        'x': 0.6,
        'y': 0.7,
      });
    });

    for (final (wire, outcome) in const [
      ('completed', RemoteTouchReleaseOutcome.completed),
      ('unavailable', RemoteTouchReleaseOutcome.unavailable),
      ('ended', RemoteTouchReleaseOutcome.ended),
      ('something new', RemoteTouchReleaseOutcome.ended),
    ]) {
      test('"$wire" is ${outcome.name}', () async {
        answerWith((_) => wire);

        expect(
          await client.releaseTouch(touch: 1, seq: 1, x: 0, y: 0),
          outcome,
        );
      });
    }

    test('a bridge that never answers ends the touch', () async {
      final never = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => never.future);

      expect(
        await client.releaseTouch(touch: 1, seq: 1, x: 0, y: 0),
        RemoteTouchReleaseOutcome.ended,
      );
    });
  });

  group('cancelRemoteTouch and abandonRemoteTouch', () {
    test('a cancel sends the handle and the seq, and completes', () async {
      answerWith((_) => 'cancelled');

      await client.cancelTouch(touch: 3, seq: 41);

      expect(calls.single.method, 'cancelRemoteTouch');
      expect(calls.single.arguments, {'touch': 3, 'seq': 41});
    });

    test('a cancel never throws, and never hangs', () async {
      final never = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => never.future);

      await expectLater(client.cancelTouch(touch: 1, seq: 1), completes);
    });

    test('abandon sends the handle and waits for nothing', () async {
      answerWith((_) => null);

      client.abandonTouch(touch: 3);
      await Future<void>.delayed(Duration.zero);

      expect(calls.single.method, 'abandonRemoteTouch');
      expect(calls.single.arguments, {'touch': 3});
    });

    test('abandon with no bridge does not throw', () async {
      client.abandonTouch(touch: 3);
      await Future<void>.delayed(Duration.zero);
    });
  });

  group('remoteTouchEnded', () {
    test('a touch the Android side ended reaches the stream', () async {
      final ends = <int>[];
      final subscription = client.touchEnds.listen(ends.add);
      addTearDown(subscription.cancel);

      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('remoteTouchEnded', 3)),
        (_) {},
      );
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall('remoteTouchEnded', 'not a handle'),
        ),
        (_) {},
      );

      expect(ends, [3]);
    });

    test('status changes and touch ends share one handler', () async {
      final statuses = <RemoteControlAccessibilityStatus>[];
      final ends = <int>[];
      final statusSubscription = client.statusChanges.listen(statuses.add);
      final endSubscription = client.touchEnds.listen(ends.add);
      // Nobody listening to the touch ends any more does not deafen the status.
      await endSubscription.cancel();
      addTearDown(statusSubscription.cancel);

      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall('accessibilityServiceAvailabilityChanged', true),
        ),
        (_) {},
      );

      expect(statuses, [RemoteControlAccessibilityStatus.available]);
      expect(ends, isEmpty);
    });
  });
}
