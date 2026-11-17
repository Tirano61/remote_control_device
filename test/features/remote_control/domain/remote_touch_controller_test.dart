import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_command_queue.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_touch_controller.dart';

import '../../../fakes/remote_control_fakes.dart';

/// The Dart side of a remote touch, together with the queue it holds. The
/// Android side is the fake: what it does with the finger has its own JVM tests.
void main() {
  late FakeRemoteControlAccessibilityClient accessibility;
  late RemoteTouchController touches;
  late RemoteControlCommandQueue queue;
  late List<RemoteControlAck> acks;
  late List<String> logs;

  final channel = Object();
  final binding = RemoteTouchBinding(
    remoteSessionId: 'session-1',
    generation: 1,
    channel: channel,
  );

  setUp(() {
    accessibility = FakeRemoteControlAccessibilityClient();
    logs = [];
    touches = RemoteTouchController(accessibility, log: logs.add);
    queue = RemoteControlCommandQueue(accessibility, touches: touches);
    acks = [];
  });

  tearDown(() => touches.dispose());

  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// What the bloc does with a hold that passed the gate.
  bool hold({
    String id = 'hold-7',
    String touch = 't-7',
    double x = 0.4,
    double y = 0.5,
    RemoteTouchBinding? as,
  }) {
    final command = RemoteTouchHoldCommand(id: id, touch: touch, x: x, y: y);
    final onAck = touches.register(command, as ?? binding, acks.add);
    if (onAck == null) return false;
    queue.submit(command, onAck);
    return true;
  }

  void move(
    int seq, {
    double x = 0.6,
    String touch = 't-7',
    RemoteTouchBinding? as,
  }) => touches.move(
    RemoteTouchMoveCommand(id: 'mv-$seq', touch: touch, seq: seq, x: x, y: 0.5),
    as ?? binding,
    acks.add,
  );

  void release(
    int seq, {
    double x = 0.6,
    String touch = 't-7',
    RemoteTouchBinding? as,
  }) => touches.release(
    RemoteTouchReleaseCommand(
      id: 'rel-$seq',
      touch: touch,
      seq: seq,
      x: x,
      y: 0.5,
    ),
    as ?? binding,
    acks.add,
  );

  void cancel(int seq, {String touch = 't-7', RemoteTouchBinding? as}) =>
      touches.cancel(
        RemoteTouchCancelCommand(id: 'cxl-$seq', touch: touch, seq: seq),
        as ?? binding,
        acks.add,
      );

  RemoteControlAck ended(String id) =>
      RemoteControlAck.failure(id, RemoteControlError.touchEnded);

  /// A hold that has started and been answered `held`.
  Future<void> held() async {
    hold();
    await settle();
    accessibility.answerStart();
    await settle();
    expect(acks, const [RemoteControlAck.success('hold-7')]);
    acks.clear();
  }

  group('the hold', () {
    test(
      'starts the touch with a handle of its own, not the sender\'s name',
      () async {
        hold(x: 0.41, y: 0.52);
        await settle();

        expect(accessibility.touchCalls, [('start', 1, 0.41, 0.52)]);
        expect(acks, isEmpty, reason: 'answered when the hold is over');
      },
    );

    test('is acknowledged ok once the Android side says it is held', () async {
      hold();
      await settle();
      accessibility.answerStart();
      await settle();

      expect(acks, const [RemoteControlAck.success('hold-7')]);
      expect(touches.isActive, isTrue);
      expect(logs, ['touch t-7 started', 'touch t-7 held']);
    });

    test('each touch gets a new handle', () async {
      await held();
      release(1);
      accessibility.answerRelease();
      await settle();

      hold(id: 'hold-8', touch: 't-7');
      await settle();

      expect(accessibility.touchCalls.last, ('start', 2, 0.4, 0.5));
    });

    for (final (outcome, error) in const [
      (
        RemoteTouchStartOutcome.unsupported,
        RemoteControlError.unsupportedCommand,
      ),
      (
        RemoteTouchStartOutcome.unavailable,
        RemoteControlError.accessibilityUnavailable,
      ),
      (RemoteTouchStartOutcome.rejected, RemoteControlError.gestureRejected),
      (RemoteTouchStartOutcome.ended, RemoteControlError.touchEnded),
    ]) {
      test(
        '${outcome.name} is ${error.name}, and leaves no touch behind',
        () async {
          hold();
          await settle();
          accessibility.answerStart(outcome);
          await settle();

          expect(acks, [RemoteControlAck.failure('hold-7', error)]);
          expect(touches.isActive, isFalse);
          // The Android side is told to let go, whatever it kept.
          expect(accessibility.touchCalls.last, ('abandon', 1));

          queue.submit(const RemoteHomeCommand(id: 'home-1'), acks.add);
          await settle();
          expect(accessibility.globalActions, ['home']);
        },
      );
    }

    test('below Android 8.0 there is no touch, only the long press', () async {
      accessibility.touchStartOutcome = RemoteTouchStartOutcome.unsupported;
      hold();
      await settle();

      expect(acks, const [
        RemoteControlAck.failure(
          'hold-7',
          RemoteControlError.unsupportedCommand,
        ),
      ]);
      expect(touches.isActive, isFalse);

      queue.submit(
        const RemoteLongPressCommand(id: 'long-1', x: 0.4, y: 0.5),
        acks.add,
      );
      await settle();
      expect(accessibility.longPresses, [(0.4, 0.5)]);
      expect(acks.last, const RemoteControlAck.success('long-1'));
    });

    test('a second hold is refused while one exists', () async {
      await held();

      expect(hold(id: 'hold-8', touch: 't-8'), isFalse);
      expect(
        accessibility.touchCalls.whereType<(String, int, double, double)>(),
        hasLength(1),
      );
    });
  });

  group('the queue keeps its place for the whole touch', () {
    test('a Home queued after the hold waits until the release', () async {
      await held();
      queue.submit(const RemoteHomeCommand(id: 'home-1'), acks.add);
      await settle();

      expect(touches.isActive, isTrue);
      expect(accessibility.globalActions, isEmpty);

      move(1);
      await settle();
      expect(accessibility.globalActions, isEmpty);

      release(2);
      await settle();
      expect(accessibility.globalActions, isEmpty);

      accessibility.answerRelease();
      await settle();
      expect(accessibility.globalActions, ['home']);
      expect(acks, const [
        RemoteControlAck.success('rel-2'),
        RemoteControlAck.success('home-1'),
      ]);
    });

    test('a Home queued after the hold waits until the cancel', () async {
      await held();
      queue.submit(const RemoteHomeCommand(id: 'home-1'), acks.add);
      cancel(1);
      await settle();
      expect(accessibility.globalActions, isEmpty);

      accessibility.answerCancel();
      await settle();
      expect(accessibility.globalActions, ['home']);
      expect(acks, const [
        RemoteControlAck.success('cxl-1'),
        RemoteControlAck.success('home-1'),
      ]);
    });

    test('nothing discrete runs under the finger, of any kind', () async {
      await held();
      queue
        ..submit(const RemoteTapCommand(id: 'tap', x: 0.5, y: 0.5), acks.add)
        ..submit(
          const RemoteLongPressCommand(id: 'long', x: 0.5, y: 0.5),
          acks.add,
        )
        ..submit(
          const RemoteSwipeCommand(
            id: 'swipe',
            startX: 0.1,
            startY: 0.1,
            endX: 0.9,
            endY: 0.9,
            durationMs: 300,
          ),
          acks.add,
        )
        ..submit(const RemoteBackCommand(id: 'back'), acks.add)
        ..submit(const RemoteHomeCommand(id: 'home'), acks.add)
        ..submit(const RemoteRecentsCommand(id: 'recents'), acks.add)
        ..submit(const RemoteSetTextCommand(id: 'text', text: 'x'), acks.add)
        ..submit(const RemoteImeEnterCommand(id: 'enter'), acks.add);
      await settle();

      expect(accessibility.gestures, [('touch_hold', 0.4, 0.5)]);
      expect(acks, isEmpty);
    });

    test('the touch ending on the Android side lets the queue go on', () async {
      await held();
      queue.submit(const RemoteHomeCommand(id: 'home-1'), acks.add);
      await settle();

      accessibility.pushTouchEnded(1);
      await settle();

      expect(touches.isActive, isFalse);
      expect(accessibility.globalActions, ['home']);
      move(1);
      expect(acks.last, ended('mv-1'));
    });

    test('a report about another handle changes nothing', () async {
      await held();
      accessibility.pushTouchEnded(99);
      await settle();

      expect(touches.isActive, isTrue);
    });

    test('follow-ups never wait in the queue', () async {
      queue.submit(
        const RemoteTouchMoveCommand(
          id: 'mv-1',
          touch: 't-7',
          seq: 1,
          x: 0.5,
          y: 0.5,
        ),
        acks.add,
      );

      expect(acks, [ended('mv-1')]);
    });

    test(
      'a hold the queue cannot take is refused, and leaves no touch',
      () async {
        accessibility.holdGestures = true;
        queue.submit(
          const RemoteTapCommand(id: 'running', x: 0, y: 0),
          acks.add,
        );
        await settle();
        for (var i = 0; i < RemoteControlCommandQueue.maxPending; i++) {
          queue.submit(RemoteTapCommand(id: 'q-$i', x: 0, y: 0), acks.add);
        }

        expect(hold(), isTrue);
        expect(acks, const [
          RemoteControlAck.failure(
            'hold-7',
            RemoteControlError.gestureRejected,
          ),
        ]);
        expect(touches.isActive, isFalse);
        expect(hold(id: 'hold-8'), isTrue, reason: 'the slot is free again');
      },
    );
  });

  group('moves', () {
    test('a move that was taken gets no ack', () async {
      await held();
      move(1, x: 0.6);
      move(2, x: 0.7);
      await settle();

      expect(acks, isEmpty);
      expect(accessibility.touchCalls.skip(1), [
        ('move', 1, 1, 0.6, 0.5),
        ('move', 1, 2, 0.7, 0.5),
      ]);
    });

    test('moves before the hold is answered reach the Android side', () async {
      hold();
      await settle();
      move(1, x: 0.6);
      move(2, x: 0.6);
      await settle();

      expect(
        accessibility.touchCalls
            .whereType<(String, int, int, double, double)>(),
        hasLength(2),
      );
      expect(acks, isEmpty);
    });

    test(
      'a move the Android side refuses is answered touch_ended, and ends the touch',
      () async {
        await held();
        accessibility.touchMoveOutcome = RemoteTouchMoveOutcome.ended;
        move(1);
        await settle();

        expect(acks, [ended('mv-1')]);
        expect(touches.isActive, isFalse);
      },
    );

    test('with no service a move is accessibility_unavailable', () async {
      await held();
      accessibility.touchMoveOutcome = RemoteTouchMoveOutcome.unavailable;
      move(1);
      await settle();

      expect(acks, const [
        RemoteControlAck.failure(
          'mv-1',
          RemoteControlError.accessibilityUnavailable,
        ),
      ]);
    });

    test('a move with no touch is touch_ended', () {
      move(1);

      expect(acks, [ended('mv-1')]);
      expect(accessibility.touchCalls, isEmpty);
    });

    test(
      'a move after the release is touch_ended, and moves nothing',
      () async {
        await held();
        release(1);
        move(2);
        await settle();

        expect(acks, [ended('mv-2')]);
        expect(accessibility.touchCalls.last, ('release', 1, 1, 0.6, 0.5));
      },
    );
  });

  group('seq', () {
    test('equal to the last one ends the touch', () async {
      await held();
      move(3);
      move(3, x: 0.9);
      await settle();

      expect(acks, [ended('mv-3')]);
      expect(touches.isActive, isFalse);
      expect(accessibility.touchCalls.last, ('abandon', 1));
      expect(logs.last, 'touch t-7 cancelled reason=sequence');
    });

    test('lower than the last one ends the touch, even on a release', () async {
      await held();
      move(5);
      release(4);
      await settle();

      expect(acks, [ended('rel-4')]);
      expect(
        accessibility.touchCalls.any(
          (call) =>
              call is (String, int, int, double, double) &&
              call.$1 == 'release',
        ),
        isFalse,
      );
    });

    test(
      'lower than the last one on a cancel ends it, answered touch_ended',
      () async {
        await held();
        move(5);
        cancel(2);
        await settle();

        expect(acks, [ended('cxl-2')]);
        expect(touches.isActive, isFalse);
      },
    );

    test('gaps are allowed', () async {
      await held();
      move(2);
      move(40);
      await settle();

      expect(acks, isEmpty);
      expect(touches.isActive, isTrue);
    });
  });

  group('one touch, bound to where it came from', () {
    test('another touch name cannot move, release or cancel it', () async {
      await held();
      move(1, touch: 'other');
      release(2, touch: 'other');
      cancel(3, touch: 'other');
      await settle();

      expect(acks, [
        ended('mv-1'),
        ended('rel-2'),
        const RemoteControlAck.success('cxl-3'),
      ]);
      expect(touches.isActive, isTrue);
      expect(accessibility.touchCalls, hasLength(1));
      move(1);
      await settle();
      expect(
        accessibility.touchCalls,
        hasLength(2),
        reason: 'its seq was untouched',
      );
    });

    for (final (name, other) in [
      (
        'another channel',
        RemoteTouchBinding(
          remoteSessionId: 'session-1',
          generation: 1,
          channel: Object(),
        ),
      ),
      (
        'another generation',
        RemoteTouchBinding(
          remoteSessionId: 'session-1',
          generation: 2,
          channel: channel,
        ),
      ),
      (
        'another session',
        RemoteTouchBinding(
          remoteSessionId: 'session-2',
          generation: 1,
          channel: channel,
        ),
      ),
    ]) {
      test('the same name from $name is not this touch', () async {
        await held();
        move(1, as: other);
        release(2, as: other);
        cancel(3, as: other);
        await settle();

        expect(acks, [
          ended('mv-1'),
          ended('rel-2'),
          const RemoteControlAck.success('cxl-3'),
        ]);
        expect(touches.isActive, isTrue);
        expect(accessibility.touchCalls, hasLength(1));
      });
    }
  });

  group('release', () {
    test('is acknowledged when the final stroke completed', () async {
      await held();
      release(1, x: 0.7);
      await settle();
      expect(acks, isEmpty);

      accessibility.answerRelease();
      await settle();
      expect(acks, const [RemoteControlAck.success('rel-1')]);
      expect(touches.isActive, isFalse);
      expect(logs.last, 'touch t-7 released');
    });

    test(
      'a release the Android side could not finish is touch_ended',
      () async {
        await held();
        release(1);
        await settle();
        accessibility.answerRelease(RemoteTouchReleaseOutcome.ended);
        await settle();

        expect(acks, [ended('rel-1')]);
      },
    );

    test(
      'a release during the hold goes now, and both are answered in order',
      () async {
        hold();
        await settle();
        release(1);
        await settle();
        expect(accessibility.touchCalls.last, ('release', 1, 1, 0.6, 0.5));

        accessibility.answerStart();
        await settle();
        accessibility.answerRelease();
        await settle();

        expect(acks, const [
          RemoteControlAck.success('hold-7'),
          RemoteControlAck.success('rel-1'),
        ]);
      },
    );

    test('a second release is touch_ended', () async {
      await held();
      release(1);
      release(2);
      await settle();

      expect(acks, [ended('rel-2')]);
    });
  });

  group('cancel', () {
    test('goes to the Android side and is ok when that is done', () async {
      await held();
      cancel(1);
      await settle();
      expect(accessibility.touchCalls.last, ('cancel', 1, 1));
      expect(acks, isEmpty);

      accessibility.answerCancel();
      await settle();
      expect(acks, const [RemoteControlAck.success('cxl-1')]);
      expect(touches.isActive, isFalse);
      expect(logs.last, 'touch t-7 cancelled reason=cancel');
    });

    test('during the hold ends the hold as touch_ended', () async {
      hold();
      await settle();
      cancel(1);
      await settle();
      accessibility.answerCancel();
      await settle();
      accessibility.answerStart(RemoteTouchStartOutcome.ended);
      await settle();

      expect(acks, [ended('hold-7'), const RemoteControlAck.success('cxl-1')]);
    });

    test('during a release waits for it', () async {
      await held();
      release(1);
      cancel(2);
      await settle();
      expect(acks, isEmpty);
      expect(accessibility.touchCalls.last, ('release', 1, 1, 0.6, 0.5));

      accessibility.answerRelease();
      await settle();
      expect(acks, const [
        RemoteControlAck.success('rel-1'),
        RemoteControlAck.success('cxl-2'),
      ]);
    });

    test('twice is one cancel, answered twice', () async {
      await held();
      cancel(1);
      cancel(2);
      await settle();
      expect(accessibility.pendingTouchCancels, 1);

      accessibility.answerCancel();
      await settle();
      expect(acks, const [
        RemoteControlAck.success('cxl-1'),
        RemoteControlAck.success('cxl-2'),
      ]);
    });

    test('with no touch is ok, and touches nothing', () {
      cancel(1);

      expect(acks, const [RemoteControlAck.success('cxl-1')]);
      expect(accessibility.touchCalls, isEmpty);
    });
  });

  group('while the hold waits its turn', () {
    Future<void> behindATap() async {
      accessibility.holdGestures = true;
      queue.submit(const RemoteTapCommand(id: 'tap', x: 0, y: 0), acks.add);
      await settle();
      hold();
      await settle();
      expect(accessibility.touchCalls, isEmpty);
    }

    test('only the latest move is kept, and goes out when it starts', () async {
      await behindATap();
      move(1, x: 0.6);
      move(2, x: 0.7);
      move(3, x: 0.8);

      accessibility.finishGesture();
      await settle();

      expect(accessibility.touchCalls, [
        ('start', 1, 0.4, 0.5),
        ('move', 1, 3, 0.8, 0.5),
      ]);
      expect(acks, const [RemoteControlAck.success('tap')]);
    });

    test('a release is kept, and goes out after the start', () async {
      await behindATap();
      move(1, x: 0.6);
      release(2, x: 0.9);

      accessibility.finishGesture();
      await settle();

      expect(accessibility.touchCalls, [
        ('start', 1, 0.4, 0.5),
        ('release', 1, 2, 0.9, 0.5),
      ]);
    });

    test('a cancel means the finger never goes down', () async {
      await behindATap();
      move(1);
      cancel(2);
      expect(acks, [ended('hold-7'), const RemoteControlAck.success('cxl-2')]);

      accessibility.finishGesture();
      await settle();

      expect(accessibility.touchCalls, isEmpty);
      expect(touches.isActive, isFalse);
    });
  });

  group('abandon, which is what the session ending does', () {
    test(
      'lets go of the touch at once, without waiting for anything',
      () async {
        await held();
        queue.submit(const RemoteHomeCommand(id: 'home-1'), acks.add);
        await settle();

        queue.discardPending();

        expect(touches.isActive, isFalse);
        expect(accessibility.touchCalls.last, ('abandon', 1));
        expect(acks, const [
          RemoteControlAck.failure(
            'home-1',
            RemoteControlError.sessionNotActive,
          ),
        ]);
        await settle();
        expect(accessibility.globalActions, isEmpty);
        expect(logs.last, 'touch t-7 cancelled reason=abandoned');
      },
    );

    test('answers whatever is still owed', () async {
      hold();
      await settle();
      release(1);
      await settle();

      queue.discardPending();

      expect(acks, [ended('hold-7'), ended('rel-1')]);
      // The Android side's late answers change nothing.
      accessibility.answerStart();
      accessibility.answerRelease();
      await settle();
      expect(acks, hasLength(2));
    });

    test('a cancel in flight is answered ok', () async {
      await held();
      cancel(1);
      await settle();

      queue.discardPending();

      expect(acks, const [RemoteControlAck.success('cxl-1')]);
    });

    test('a hold still waiting is dropped like any queued command', () async {
      accessibility.holdGestures = true;
      queue.submit(const RemoteTapCommand(id: 'tap', x: 0, y: 0), acks.add);
      await settle();
      hold();
      await settle();

      queue.discardPending();
      accessibility.finishGesture();
      await settle();

      expect(acks, const [
        RemoteControlAck.failure('hold-7', RemoteControlError.sessionNotActive),
        RemoteControlAck.success('tap'),
      ]);
      expect(accessibility.touchCalls, isEmpty);
      expect(touches.isActive, isFalse);
    });

    test('after it, the next session starts a touch from scratch', () async {
      await held();
      queue.discardPending();
      await settle();

      expect(hold(id: 'hold-8'), isTrue);
      await settle();
      expect(accessibility.touchCalls.last, ('start', 2, 0.4, 0.5));
    });
  });
}
