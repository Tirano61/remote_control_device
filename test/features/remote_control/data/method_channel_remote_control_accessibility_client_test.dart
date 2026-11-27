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
      expect(calls.single.arguments, {'x': 0.25, 'y': 0.75, 'grant': 0});
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

  group('long press', () {
    test('sends the normalized position, and no duration', () async {
      answerWith((_) => 'completed');

      await client.longPress(0.25, 0.75);

      expect(calls.single.method, 'performLongPress');
      expect(calls.single.arguments, {'x': 0.25, 'y': 0.75, 'grant': 0});
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

        expect(await client.longPress(0.5, 0.5), outcome);
      });
    }

    test('a platform error is a rejection, not an exception', () async {
      answerWith((_) => throw PlatformException(code: 'BOOM'));

      expect(await client.longPress(0.5, 0.5), RemoteGestureOutcome.rejected);
    });

    test('a bridge that is not there is unavailable', () async {
      expect(
        await client.longPress(0.5, 0.5),
        RemoteGestureOutcome.unavailable,
      );
    });

    test('a bridge that never answers does not hold the queue', () async {
      final never = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => never.future);

      expect(await client.longPress(0.5, 0.5), RemoteGestureOutcome.rejected);
    });

    test('the guard outlasts the longest long press Android will hold', () {
      // MAX_LONG_PRESS_DURATION_MS in RemoteGesture.kt: the device refuses a
      // long press it would hold for longer, so the guard never cuts one short.
      const longestLongPress = Duration(milliseconds: 4000);

      expect(
        MethodChannelRemoteControlAccessibilityClient().gestureTimeout,
        greaterThan(longestLongPress),
      );
    });

    test('a long press answered after a tap would have been, is not refused '
        'while the guard has not expired', () async {
      client = MethodChannelRemoteControlAccessibilityClient(
        gestureTimeout: const Duration(seconds: 5),
      );
      messenger.setMockMethodCallHandler(channel, (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return 'completed';
      });

      expect(await client.longPress(0.5, 0.5), RemoteGestureOutcome.completed);
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
        'grant': 0,
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
      test('sends nothing but its grant: no position, and no Android '
          'code', () async {
        answerWith((_) => 'completed');

        await perform();

        expect(calls.single.method, method);
        expect(calls.single.arguments, {'grant': 0});
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

  group('performSetText', () {
    test('sends the text and nothing else about the field', () async {
      answerWith((_) => 'completed');

      await client.performSetText('Hola 👋\náéíóú ñ');

      expect(calls.single.method, 'performSetText');
      expect(calls.single.arguments, {'text': 'Hola 👋\náéíóú ñ', 'grant': 0});
    });

    test('an empty text still crosses, as an empty text', () async {
      answerWith((_) => 'completed');

      await client.performSetText('');

      expect(calls.single.arguments, {'text': '', 'grant': 0});
    });

    for (final (wire, outcome) in const [
      ('completed', RemoteTextOutcome.completed),
      ('targetUnavailable', RemoteTextOutcome.targetUnavailable),
      ('unavailable', RemoteTextOutcome.unavailable),
      ('rejected', RemoteTextOutcome.rejected),
      ('busy', RemoteTextOutcome.rejected),
      ('invalid', RemoteTextOutcome.rejected),
      ('something new', RemoteTextOutcome.rejected),
    ]) {
      test('"$wire" means $outcome', () async {
        answerWith((_) => wire);

        expect(await client.performSetText('Hola'), outcome);
      });
    }

    test('a platform error is a rejection, not an exception', () async {
      answerWith((_) => throw PlatformException(code: 'BOOM'));

      expect(await client.performSetText('Hola'), RemoteTextOutcome.rejected);
    });

    test('a bridge that is not there is unavailable', () async {
      expect(
        await client.performSetText('Hola'),
        RemoteTextOutcome.unavailable,
      );
    });

    test('a bridge that never answers does not hold the queue', () async {
      final never = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => never.future);

      expect(await client.performSetText('Hola'), RemoteTextOutcome.rejected);
    });
  });

  group('performImeEnter', () {
    test('sends nothing but its grant: no text, no key code, no action '
        'id', () async {
      answerWith((_) => 'completed');

      await client.performImeEnter();

      expect(calls.single.method, 'performImeEnter');
      expect(calls.single.arguments, {'grant': 0});
    });

    for (final (wire, outcome) in const [
      ('completed', RemoteImeEnterOutcome.completed),
      ('targetUnavailable', RemoteImeEnterOutcome.targetUnavailable),
      ('actionUnavailable', RemoteImeEnterOutcome.actionUnavailable),
      ('unavailable', RemoteImeEnterOutcome.unavailable),
      ('rejected', RemoteImeEnterOutcome.rejected),
      ('busy', RemoteImeEnterOutcome.rejected),
      ('invalid', RemoteImeEnterOutcome.rejected),
      ('something new', RemoteImeEnterOutcome.rejected),
    ]) {
      test('"$wire" means $outcome', () async {
        answerWith((_) => wire);

        expect(await client.performImeEnter(), outcome);
      });
    }

    test('a platform error is a rejection, not an exception', () async {
      answerWith((_) => throw PlatformException(code: 'BOOM'));

      expect(await client.performImeEnter(), RemoteImeEnterOutcome.rejected);
    });

    test('a bridge that is not there is unavailable', () async {
      expect(await client.performImeEnter(), RemoteImeEnterOutcome.unavailable);
    });

    test('a bridge that never answers does not hold the queue', () async {
      final never = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => never.future);

      expect(await client.performImeEnter(), RemoteImeEnterOutcome.rejected);
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
  group('the native control gate', () {
    test('openRemoteControl sends the grant and the session', () async {
      answerWith((_) => 'opened');

      expect(
        await client.openControl(grant: 4, remoteSessionId: 'rs-1'),
        RemoteControlOpenOutcome.opened,
      );

      expect(calls.single.method, 'openRemoteControl');
      expect(calls.single.arguments, {'grant': 4, 'session': 'rs-1'});
    });

    for (final (wire, outcome) in const [
      ('opened', RemoteControlOpenOutcome.opened),
      ('ended', RemoteControlOpenOutcome.ended),
      ('stale', RemoteControlOpenOutcome.stale),
      ('nonsense', RemoteControlOpenOutcome.stale),
    ]) {
      test('an opening answered $wire is ${outcome.name}', () async {
        answerWith((_) => wire);

        expect(
          await client.openControl(grant: 1, remoteSessionId: 'rs-1'),
          outcome,
        );
      });
    }

    test('an opening with no Android side is unavailable', () async {
      answerWith((_) => throw MissingPluginException());

      expect(
        await client.openControl(grant: 1, remoteSessionId: 'rs-1'),
        RemoteControlOpenOutcome.unavailable,
      );
    });

    test('every command sent after the opening carries its grant, even before '
        'the opening is answered', () async {
      final opening = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (call) {
        calls.add(call);
        if (call.method == 'openRemoteControl') return opening.future;
        return Future.value('completed');
      });

      unawaited(client.openControl(grant: 7, remoteSessionId: 'rs-1'));
      await client.tap(0.5, 0.5);
      await client.performBack();
      await client.performSetText('hola');
      await client.performImeEnter();
      opening.complete('opened');

      expect(calls.map((call) => call.method).toList(), [
        'openRemoteControl',
        'performTap',
        'performBack',
        'performSetText',
        'performImeEnter',
      ]);
      for (final call in calls.skip(1)) {
        expect((call.arguments as Map)['grant'], 7, reason: call.method);
      }
    });

    test('closeRemoteControl is sent at once, and commands after it carry no '
        'open grant', () async {
      answerWith(
        (call) => call.method == 'openRemoteControl' ? 'opened' : 'revoked',
      );
      await client.openControl(grant: 2, remoteSessionId: 'rs-1');

      client.closeControl();
      final outcome = await client.swipe(
        startX: 0.5,
        startY: 0.8,
        endX: 0.5,
        endY: 0.2,
        durationMs: 300,
      );

      expect(calls[1].method, 'closeRemoteControl');
      expect(calls[1].arguments, <String, Object>{});
      expect((calls[2].arguments as Map)['grant'], 0);
      expect(outcome, RemoteGestureOutcome.revoked);
    });

    test('closing with an ended session names it', () async {
      answerWith((_) => null);

      client.closeControl(endedRemoteSessionId: 'rs-1');
      await Future<void>.delayed(Duration.zero);

      expect(calls.single.method, 'closeRemoteControl');
      expect(calls.single.arguments, {'ended': 'rs-1'});
    });

    test('closing never throws, with or without an Android side', () async {
      answerWith((_) => throw PlatformException(code: 'BOOM'));
      client.closeControl();
      messenger.setMockMethodCallHandler(channel, null);
      client.closeControl(endedRemoteSessionId: 'rs-1');
      await Future<void>.delayed(Duration.zero);
    });

    test('revoked is understood for every kind of command', () async {
      answerWith((_) => 'revoked');

      expect(await client.tap(0.5, 0.5), RemoteGestureOutcome.revoked);
      expect(await client.longPress(0.5, 0.5), RemoteGestureOutcome.revoked);
      expect(await client.performRecents(), RemoteGestureOutcome.revoked);
      expect(await client.performSetText('hola'), RemoteTextOutcome.revoked);
      expect(await client.performImeEnter(), RemoteImeEnterOutcome.revoked);
      expect(
        await client.startTouch(touch: 1, x: 0.5, y: 0.5),
        RemoteTouchStartOutcome.revoked,
      );
      expect(
        await client.moveTouch(touch: 1, seq: 1, x: 0.5, y: 0.5),
        RemoteTouchMoveOutcome.ended,
      );
      expect(
        await client.releaseTouch(touch: 1, seq: 2, x: 0.5, y: 0.5),
        RemoteTouchReleaseOutcome.ended,
      );
    });
  });
}
