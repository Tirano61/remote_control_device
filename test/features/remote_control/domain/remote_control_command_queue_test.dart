import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_command_queue.dart';

import '../../../fakes/remote_control_fakes.dart';

void main() {
  late FakeRemoteControlAccessibilityClient accessibility;
  late RemoteControlCommandQueue queue;
  late List<RemoteControlAck> acks;

  setUp(() {
    accessibility = FakeRemoteControlAccessibilityClient();
    queue = RemoteControlCommandQueue(accessibility);
    acks = [];
  });

  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void submit(String id, {double x = 0.5}) =>
      queue.submit(RemoteTapCommand(id: id, x: x, y: 0.5), acks.add);

  RemoteSwipeCommand swipeCommand(String id) => RemoteSwipeCommand(
    id: id,
    startX: 0.1,
    startY: 0.9,
    endX: 0.1,
    endY: 0.2,
    durationMs: 300,
  );

  const swipeCall = (0.1, 0.9, 0.1, 0.2, 300);

  group('taps and swipes share one line', () {
    test('tap A, swipe B, tap C run in order, never together', () async {
      accessibility.holdGestures = true;

      submit('a', x: 0.3);
      queue.submit(swipeCommand('b'), acks.add);
      submit('c', x: 0.7);
      await settle();
      expect(accessibility.gestures, [(0.3, 0.5)]);

      accessibility.finishGesture();
      await settle();
      expect(accessibility.gestures, [(0.3, 0.5), swipeCall]);
      expect(acks, const [RemoteControlAck.success('a')]);

      accessibility.finishGesture();
      await settle();
      expect(accessibility.gestures, [(0.3, 0.5), swipeCall, (0.7, 0.5)]);
      expect(acks, const [
        RemoteControlAck.success('a'),
        RemoteControlAck.success('b'),
      ]);

      accessibility.finishGesture();
      await settle();
      expect(acks, const [
        RemoteControlAck.success('a'),
        RemoteControlAck.success('b'),
        RemoteControlAck.success('c'),
      ]);
    });

    test('a pending swipe is dropped with the rest', () async {
      accessibility.holdGestures = true;
      queue.submit(swipeCommand('a'), acks.add);
      queue.submit(swipeCommand('b'), acks.add);
      submit('c');
      await settle();

      queue.discardPending();
      accessibility.finishGesture();
      await settle();

      expect(accessibility.gestures, [swipeCall]);
      expect(acks, const [
        RemoteControlAck.failure('b', RemoteControlError.sessionNotActive),
        RemoteControlAck.failure('c', RemoteControlError.sessionNotActive),
        RemoteControlAck.success('a'),
      ]);
    });

    test('swipes count against the same limit as taps', () async {
      accessibility.holdGestures = true;
      submit('running');
      await settle();

      for (var i = 0; i < RemoteControlCommandQueue.maxPending; i++) {
        i.isEven
            ? submit('queued-$i')
            : queue.submit(swipeCommand('queued-$i'), acks.add);
      }
      queue.submit(swipeCommand('one-too-many'), acks.add);

      expect(acks, const [
        RemoteControlAck.failure(
          'one-too-many',
          RemoteControlError.gestureRejected,
        ),
      ]);
      expect(accessibility.gestures, hasLength(1));
    });
  });

  group('back and home share that line', () {
    test('tap, swipe, back, home, tap run in order, never together', () async {
      accessibility.holdGestures = true;

      submit('a', x: 0.3);
      queue.submit(swipeCommand('b'), acks.add);
      queue.submit(const RemoteBackCommand(id: 'c'), acks.add);
      queue.submit(const RemoteHomeCommand(id: 'd'), acks.add);
      submit('e', x: 0.7);
      await settle();
      expect(accessibility.gestures, [(0.3, 0.5)]);

      final expected = <Object>[
        (0.3, 0.5),
        swipeCall,
        'back',
        'home',
        (0.7, 0.5),
      ];
      for (var finished = 1; finished < expected.length; finished++) {
        accessibility.finishGesture();
        await settle();
        expect(accessibility.gestures, expected.take(finished + 1));
        expect(acks, hasLength(finished));
      }

      accessibility.finishGesture();
      await settle();
      expect(acks, const [
        RemoteControlAck.success('a'),
        RemoteControlAck.success('b'),
        RemoteControlAck.success('c'),
        RemoteControlAck.success('d'),
        RemoteControlAck.success('e'),
      ]);
    });

    test('home waits for a swipe that is still running', () async {
      accessibility.holdGestures = true;

      queue.submit(swipeCommand('a'), acks.add);
      queue.submit(const RemoteHomeCommand(id: 'b'), acks.add);
      await settle();

      expect(accessibility.gestures, [swipeCall]);
      expect(accessibility.globalActions, isEmpty);

      accessibility.finishGesture();
      await settle();

      expect(accessibility.gestures, [swipeCall, 'home']);
    });

    test('a pending back and home are dropped with the rest', () async {
      accessibility.holdGestures = true;
      submit('a');
      queue.submit(const RemoteBackCommand(id: 'b'), acks.add);
      queue.submit(const RemoteHomeCommand(id: 'c'), acks.add);
      await settle();

      queue.discardPending();
      accessibility.finishGesture();
      await settle();

      expect(accessibility.globalActions, isEmpty);
      expect(acks, const [
        RemoteControlAck.failure('b', RemoteControlError.sessionNotActive),
        RemoteControlAck.failure('c', RemoteControlError.sessionNotActive),
        RemoteControlAck.success('a'),
      ]);
    });

    test('they count against the same limit', () async {
      accessibility.holdGestures = true;
      submit('running');
      await settle();

      for (var i = 0; i < RemoteControlCommandQueue.maxPending; i++) {
        queue.submit(RemoteBackCommand(id: 'queued-$i'), acks.add);
      }
      queue.submit(const RemoteHomeCommand(id: 'one-too-many'), acks.add);

      expect(acks, const [
        RemoteControlAck.failure(
          'one-too-many',
          RemoteControlError.gestureRejected,
        ),
      ]);
      expect(accessibility.globalActions, isEmpty);
    });

    for (final (command, action) in const [
      (RemoteBackCommand(id: 'n'), 'back'),
      (RemoteHomeCommand(id: 'n'), 'home'),
    ]) {
      for (final (outcome, ack) in const [
        (RemoteGestureOutcome.completed, RemoteControlAck.success('n')),
        (
          RemoteGestureOutcome.rejected,
          RemoteControlAck.failure('n', RemoteControlError.gestureRejected),
        ),
        (
          RemoteGestureOutcome.unavailable,
          RemoteControlAck.failure(
            'n',
            RemoteControlError.accessibilityUnavailable,
          ),
        ),
      ]) {
        test('$outcome on a $action becomes the matching ack', () async {
          accessibility.outcome = outcome;

          queue.submit(command, acks.add);
          await settle();

          expect(acks, [ack]);
          expect(accessibility.gestures, [action]);
        });
      }
    }
  });

  for (final (outcome, ack) in const [
    (RemoteGestureOutcome.completed, RemoteControlAck.success('s')),
    (
      RemoteGestureOutcome.rejected,
      RemoteControlAck.failure('s', RemoteControlError.gestureRejected),
    ),
    (
      RemoteGestureOutcome.unavailable,
      RemoteControlAck.failure(
        's',
        RemoteControlError.accessibilityUnavailable,
      ),
    ),
  ]) {
    test('$outcome on a swipe becomes the matching ack', () async {
      accessibility.outcome = outcome;

      queue.submit(swipeCommand('s'), acks.add);
      await settle();

      expect(acks, [ack]);
      expect(accessibility.swipes, [swipeCall]);
    });
  }

  test('A starts, B waits, A completes, B starts', () async {
    accessibility.holdGestures = true;

    submit('a', x: 0.1);
    submit('b', x: 0.2);
    await settle();
    expect(accessibility.taps, [(0.1, 0.5)]);

    accessibility.finishGesture();
    await settle();
    expect(accessibility.taps, [(0.1, 0.5), (0.2, 0.5)]);
    expect(acks, const [RemoteControlAck.success('a')]);
  });

  test('discarding before B starts means B never runs', () async {
    accessibility.holdGestures = true;
    submit('a');
    submit('b');
    await settle();

    queue.discardPending();
    expect(acks, const [
      RemoteControlAck.failure('b', RemoteControlError.sessionNotActive),
    ]);

    accessibility.finishGesture();
    await settle();

    expect(accessibility.taps, hasLength(1));
    expect(acks.last, const RemoteControlAck.success('a'));
  });

  test('the queue keeps working after a discard', () async {
    submit('a');
    await settle();
    queue.discardPending();

    submit('b');
    await settle();

    expect(accessibility.taps, hasLength(2));
  });

  test('a flood is refused, not stored', () async {
    accessibility.holdGestures = true;
    submit('running');
    await settle();

    for (var i = 0; i < RemoteControlCommandQueue.maxPending; i++) {
      submit('queued-$i');
    }
    submit('one-too-many');

    expect(acks, const [
      RemoteControlAck.failure(
        'one-too-many',
        RemoteControlError.gestureRejected,
      ),
    ]);
    expect(accessibility.taps, hasLength(1));
  });

  for (final (outcome, ack) in const [
    (RemoteGestureOutcome.completed, RemoteControlAck.success('t')),
    (
      RemoteGestureOutcome.rejected,
      RemoteControlAck.failure('t', RemoteControlError.gestureRejected),
    ),
    (
      RemoteGestureOutcome.unavailable,
      RemoteControlAck.failure(
        't',
        RemoteControlError.accessibilityUnavailable,
      ),
    ),
  ]) {
    test('$outcome becomes the matching ack', () async {
      accessibility.outcome = outcome;

      submit('t');
      await settle();

      expect(acks, [ack]);
    });
  }
}
