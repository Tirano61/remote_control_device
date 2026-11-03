import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/remote_control/data/method_channel_remote_control_accessibility_client.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';

/// The Dart half of the bridge, against a mock of the Android half. The channel
/// name and the method names are the contract with
/// `RemoteControlAccessibilityChannel.kt`, so they are spelled out here rather
/// than read from the class under test.
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

  group('status', () {
    test('asks the service', () async {
      answerWith((_) => true);

      expect(
        await client.currentStatus(),
        RemoteControlAccessibilityStatus.available,
      );
      expect(calls.single.method, 'isAccessibilityServiceAvailable');
    });

    test('a service that is not connected is unavailable', () async {
      answerWith((_) => false);

      expect(
        await client.currentStatus(),
        RemoteControlAccessibilityStatus.unavailable,
      );
    });

    test('a bridge that is not there is unavailable, not an error', () async {
      expect(
        await client.currentStatus(),
        RemoteControlAccessibilityStatus.unavailable,
      );
    });

    test('a change pushed by Android reaches the stream', () async {
      final changes = <RemoteControlAccessibilityStatus>[];
      final subscription = client.statusChanges.listen(changes.add);
      addTearDown(subscription.cancel);

      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall('accessibilityServiceAvailabilityChanged', true),
        ),
        (_) {},
      );
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall('accessibilityServiceAvailabilityChanged', false),
        ),
        (_) {},
      );

      expect(changes, [
        RemoteControlAccessibilityStatus.available,
        RemoteControlAccessibilityStatus.unavailable,
      ]);
    });
  });

  group('tap', () {
    test('sends the normalized position, and no pixels', () async {
      answerWith((_) => 'completed');

      await client.tap(0.25, 0.75);

      expect(calls.single.method, 'performTap');
      expect(calls.single.arguments, {'x': 0.25, 'y': 0.75});
    });

    for (final (wire, outcome) in const [
      ('completed', RemoteGestureOutcome.completed),
      ('unavailable', RemoteGestureOutcome.unavailable),
      ('cancelled', RemoteGestureOutcome.rejected),
      ('rejected', RemoteGestureOutcome.rejected),
      ('busy', RemoteGestureOutcome.rejected),
      ('invalid', RemoteGestureOutcome.rejected),
      ('something new', RemoteGestureOutcome.rejected),
    ]) {
      test('"$wire" means $outcome', () async {
        answerWith((_) => wire);

        expect(await client.tap(0.5, 0.5), outcome);
      });
    }

    test('a platform error is a rejection, not an exception', () async {
      answerWith((_) => throw PlatformException(code: 'BOOM'));

      expect(await client.tap(0.5, 0.5), RemoteGestureOutcome.rejected);
    });

    test('a bridge that is not there is unavailable', () async {
      expect(await client.tap(0.5, 0.5), RemoteGestureOutcome.unavailable);
    });

    test('a bridge that never answers does not hold the queue', () async {
      final never = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => never.future);

      expect(await client.tap(0.5, 0.5), RemoteGestureOutcome.rejected);
    });
  });

  group('swipe', () {
    Future<RemoteGestureOutcome> swipe() => client.swipe(
      startX: 0.5,
      startY: 0.75,
      endX: 0.25,
      endY: 0.125,
      durationMs: 350,
    );

    test('sends normalized positions and the duration, no pixels', () async {
      answerWith((_) => 'completed');

      await swipe();

      expect(calls.single.method, 'performSwipe');
      expect(calls.single.arguments, {
        'startX': 0.5,
        'startY': 0.75,
        'endX': 0.25,
        'endY': 0.125,
        'durationMs': 350,
      });
    });

    for (final (wire, outcome) in const [
      ('completed', RemoteGestureOutcome.completed),
      ('unavailable', RemoteGestureOutcome.unavailable),
      ('cancelled', RemoteGestureOutcome.rejected),
      ('rejected', RemoteGestureOutcome.rejected),
      ('busy', RemoteGestureOutcome.rejected),
      ('invalid', RemoteGestureOutcome.rejected),
      ('something new', RemoteGestureOutcome.rejected),
    ]) {
      test('"$wire" means $outcome', () async {
        answerWith((_) => wire);

        expect(await swipe(), outcome);
      });
    }

    test('a platform error is a rejection, not an exception', () async {
      answerWith((_) => throw PlatformException(code: 'BOOM'));

      expect(await swipe(), RemoteGestureOutcome.rejected);
    });

    test('a bridge that is not there is unavailable', () async {
      expect(await swipe(), RemoteGestureOutcome.unavailable);
    });

    test('a bridge that never answers does not hold the queue', () async {
      final never = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => never.future);

      expect(await swipe(), RemoteGestureOutcome.rejected);
    });

    test('the guard outlasts the longest swipe the protocol allows', () {
      expect(
        MethodChannelRemoteControlAccessibilityClient().gestureTimeout,
        greaterThan(
          const Duration(milliseconds: RemoteSwipeCommand.maxDurationMs),
        ),
      );
    });

    test('a swipe answered before the guard expires is not refused', () async {
      client = MethodChannelRemoteControlAccessibilityClient(
        gestureTimeout: const Duration(seconds: 5),
      );
      messenger.setMockMethodCallHandler(channel, (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return 'completed';
      });

      expect(await swipe(), RemoteGestureOutcome.completed);
    });
  });

  for (final (method, perform) in [
    ('performBack', () => client.performBack()),
    ('performHome', () => client.performHome()),
    ('performRecents', () => client.performRecents()),
  ]) {
    group(method, () {
      test('sends no arguments: no position, and no Android code', () async {
        answerWith((_) => 'completed');

        await perform();

        expect(calls.single.method, method);
        expect(calls.single.arguments, isNull);
      });

      for (final (wire, outcome) in const [
        ('completed', RemoteGestureOutcome.completed),
        ('unavailable', RemoteGestureOutcome.unavailable),
        ('rejected', RemoteGestureOutcome.rejected),
        ('busy', RemoteGestureOutcome.rejected),
        ('something new', RemoteGestureOutcome.rejected),
      ]) {
        test('"$wire" means $outcome', () async {
          answerWith((_) => wire);

          expect(await perform(), outcome);
        });
      }

      test('a platform error is a rejection, not an exception', () async {
        answerWith((_) => throw PlatformException(code: 'BOOM'));

        expect(await perform(), RemoteGestureOutcome.rejected);
      });

      test('a bridge that is not there is unavailable', () async {
        expect(await perform(), RemoteGestureOutcome.unavailable);
      });

      test('a bridge that never answers does not hold the queue', () async {
        final never = Completer<Object?>();
        messenger.setMockMethodCallHandler(channel, (_) => never.future);

        expect(await perform(), RemoteGestureOutcome.rejected);
      });
    });
  }

  group('settings', () {
    test('only asks Android to open them', () async {
      answerWith((_) => null);

      await client.openAccessibilitySettings();

      expect(calls.single.method, 'openAccessibilitySettings');
    });

    test('never throws', () async {
      answerWith((_) => throw PlatformException(code: 'BOOM'));

      await expectLater(client.openAccessibilitySettings(), completes);
    });
  });
}
