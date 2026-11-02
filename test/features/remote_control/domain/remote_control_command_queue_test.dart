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
