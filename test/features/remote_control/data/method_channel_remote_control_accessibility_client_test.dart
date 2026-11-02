import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/remote_control/data/method_channel_remote_control_accessibility_client.dart';
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
      tapTimeout: const Duration(milliseconds: 20),
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
      ('completed', RemoteTapOutcome.completed),
      ('unavailable', RemoteTapOutcome.unavailable),
      ('cancelled', RemoteTapOutcome.rejected),
      ('rejected', RemoteTapOutcome.rejected),
      ('busy', RemoteTapOutcome.rejected),
      ('invalid', RemoteTapOutcome.rejected),
      ('something new', RemoteTapOutcome.rejected),
    ]) {
      test('"$wire" means $outcome', () async {
        answerWith((_) => wire);

        expect(await client.tap(0.5, 0.5), outcome);
      });
    }

    test('a platform error is a rejection, not an exception', () async {
      answerWith((_) => throw PlatformException(code: 'BOOM'));

      expect(await client.tap(0.5, 0.5), RemoteTapOutcome.rejected);
    });

    test('a bridge that is not there is unavailable', () async {
      expect(await client.tap(0.5, 0.5), RemoteTapOutcome.unavailable);
    });

    test('a bridge that never answers does not hold the queue', () async {
      final never = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => never.future);

      expect(await client.tap(0.5, 0.5), RemoteTapOutcome.rejected);
    });
  });

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
