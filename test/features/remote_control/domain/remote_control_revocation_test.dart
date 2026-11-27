import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_command_queue.dart';

import '../../../fakes/remote_control_fakes.dart';

/// A2 of the Prompt 44 audit, on the Dart side of the bridge: a gesture that
/// was already running when the authority was withdrawn must never be reported
/// to the technician as done, whatever Android says about it afterwards.
void main() {
  late FakeRemoteControlAccessibilityClient accessibility;
  late RemoteControlCommandQueue queue;
  late List<RemoteControlAck> acks;

  setUp(() {
    accessibility = FakeRemoteControlAccessibilityClient()..holdGestures = true;
    queue = RemoteControlCommandQueue(accessibility);
    acks = [];
  });

  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  const swipe = RemoteSwipeCommand(
    id: 'swipe-1',
    startX: 0.5,
    startY: 0.8,
    endX: 0.5,
    endY: 0.2,
    durationMs: 2000,
  );

  test('A2: a swipe that Android completes after the revocation is not '
      'reported ok', () async {
    queue.submit(swipe, acks.add);
    await settle();
    expect(accessibility.swipes, hasLength(1), reason: 'the swipe is running');

    // The authority is withdrawn while Android is still playing the stroke.
    queue.discardPending();
    await settle();

    // Android finishes the stroke it already had and reports it completed.
    accessibility.finishGesture(RemoteGestureOutcome.completed);
    await settle();

    expect(acks, const [
      RemoteControlAck.failure('swipe-1', RemoteControlError.sessionNotActive),
    ]);
  });

  test(
    'a swipe Android cancelled on the revocation answers session_not_active',
    () async {
      queue.submit(swipe, acks.add);
      await settle();
      queue.discardPending();

      accessibility.finishGesture(RemoteGestureOutcome.revoked);
      await settle();

      expect(acks, const [
        RemoteControlAck.failure(
          'swipe-1',
          RemoteControlError.sessionNotActive,
        ),
      ]);
    },
  );

  test('a failure after the revocation stays the failure it was', () async {
    queue.submit(swipe, acks.add);
    await settle();
    queue.discardPending();

    accessibility.finishGesture(RemoteGestureOutcome.rejected);
    await settle();

    expect(acks, const [
      RemoteControlAck.failure('swipe-1', RemoteControlError.gestureRejected),
    ]);
  });

  test('a gesture that answered before the revocation keeps its ok', () async {
    queue.submit(swipe, acks.add);
    await settle();
    accessibility.finishGesture(RemoteGestureOutcome.completed);
    await settle();

    queue.discardPending();

    expect(acks, const [RemoteControlAck.success('swipe-1')]);
  });

  test(
    'a command of a new authority after the revocation answers normally',
    () async {
      queue.submit(swipe, acks.add);
      await settle();
      queue.discardPending();
      queue.submit(
        const RemoteTapCommand(id: 'tap-2', x: 0.5, y: 0.5),
        acks.add,
      );
      accessibility.finishGesture(RemoteGestureOutcome.completed);
      await settle();

      accessibility.finishGesture(RemoteGestureOutcome.completed);
      await settle();

      expect(acks, const [
        RemoteControlAck.failure(
          'swipe-1',
          RemoteControlError.sessionNotActive,
        ),
        RemoteControlAck.success('tap-2'),
      ]);
    },
  );

  test(
    'revoked from the Android side is session_not_active for every kind',
    () async {
      accessibility
        ..holdGestures = false
        ..outcome = RemoteGestureOutcome.revoked
        ..textOutcome = RemoteTextOutcome.revoked
        ..imeEnterOutcome = RemoteImeEnterOutcome.revoked;

      queue.submit(const RemoteTapCommand(id: 'a', x: 0.5, y: 0.5), acks.add);
      queue.submit(const RemoteBackCommand(id: 'b'), acks.add);
      queue.submit(const RemoteSetTextCommand(id: 'c', text: 'x'), acks.add);
      queue.submit(const RemoteImeEnterCommand(id: 'd'), acks.add);
      await settle();

      expect(acks.map((ack) => (ack.id, ack.error)), [
        ('a', RemoteControlError.sessionNotActive),
        ('b', RemoteControlError.sessionNotActive),
        ('c', RemoteControlError.sessionNotActive),
        ('d', RemoteControlError.sessionNotActive),
      ]);
    },
  );

  test(
    'the log tells a late success apart, without the command contents',
    () async {
      final lines = <String>[];
      queue = RemoteControlCommandQueue(accessibility, log: lines.add);
      queue.submit(swipe, acks.add);
      await settle();
      queue.discardPending();
      accessibility.finishGesture(RemoteGestureOutcome.completed);
      await settle();

      expect(lines.single, contains('swipe-1'));
      expect(lines.single, contains('outcome unknown by race'));
    },
  );
}
