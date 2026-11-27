import 'dart:collection';

import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_touch_controller.dart';

/// Runs commands one at a time, in the order they were submitted.
///
/// The channel delivers them in order, but a gesture takes time, and a second
/// `dispatchGesture` would cancel the first. So the next command starts when
/// the previous one has finished.
///
/// It does not decide whether a command may run: the caller checks that before
/// submitting, and calls [discardPending] the moment the answer changes. A
/// gesture already running is cancelled on the Android side by the closing of
/// the native control gate, where Android allows it; here, whatever its answer
/// turns out to be, it is never reported as done once its authority was
/// withdrawn while it ran (A2 of the Prompt 44 audit). It was sent under an
/// authority that no longer holds, and what Android did with it in the
/// meantime cannot be told apart from a race with the revocation.
///
/// A `touch_hold` takes its turn like any command and keeps it until its touch
/// has ended, which is later than its ack: [RemoteTouchController.run] is what
/// the queue waits on, not the hold. Nothing queued behind it runs while the
/// finger is down. A remote touch is the one thing [discardPending] does not
/// leave to finish, because it never finishes by itself.
class RemoteControlCommandQueue {
  RemoteControlCommandQueue(
    this._accessibility, {
    RemoteTouchController? touches,
    void Function(String message)? log,
  }) : touches = touches ?? RemoteTouchController(_accessibility),
       _log = log ?? _silent;

  /// A browser that floods the channel gets refusals rather than taps that run
  /// long after anyone meant them.
  static const int maxPending = 16;

  final RemoteControlAccessibilityClient _accessibility;

  /// The remote touch a `touch_hold` in this queue starts, and that its
  /// `touch_move`, `touch_release` and `touch_cancel` go to directly.
  final RemoteTouchController touches;

  final void Function(String message) _log;

  final Queue<_Pending> _pending = Queue<_Pending>();
  bool _draining = false;

  /// Moves on every [discardPending]. A command that started under one value
  /// and answers under another had its authority withdrawn while it ran.
  int _revocations = 0;

  /// Queues [command]. [onAck] is called exactly once, with what became of it.
  ///
  /// A `touch_hold` is registered with [touches] before it gets here, and
  /// [onAck] is then the sink [RemoteTouchController.register] answered. The
  /// messages that follow a hold never queue.
  void submit(
    RemoteControlCommand command,
    void Function(RemoteControlAck ack) onAck,
  ) {
    if (command is RemoteTouchFollowUpCommand) {
      onAck(
        RemoteControlAck.failure(command.id, RemoteControlError.touchEnded),
      );
      return;
    }
    if (_pending.length >= maxPending) {
      onAck(
        RemoteControlAck.failure(
          command.id,
          RemoteControlError.gestureRejected,
        ),
      );
      if (command is RemoteTouchHoldCommand) touches.drop(command);
      return;
    }
    _pending.add(_Pending(command, onAck));
    _drain();
  }

  /// Ends the remote touch, if there is one, without waiting, and then drops
  /// everything that has not started. Each of those is answered as refused,
  /// since nothing will run it.
  void discardPending() {
    _revocations++;
    touches.abandon();
    while (_pending.isNotEmpty) {
      final pending = _pending.removeFirst();
      pending.onAck(
        RemoteControlAck.failure(
          pending.command.id,
          RemoteControlError.sessionNotActive,
        ),
      );
      if (pending.command case final RemoteTouchHoldCommand hold) {
        touches.drop(hold);
      }
    }
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    while (_pending.isNotEmpty) {
      final pending = _pending.removeFirst();
      if (pending.command case final RemoteTouchHoldCommand hold) {
        await touches.run(hold, pending.onAck);
        continue;
      }
      final startedUnder = _revocations;
      final ack = await _execute(pending.command);
      pending.onAck(
        startedUnder == _revocations
            ? ack
            : _afterRevocation(pending.command, ack),
      );
    }
    _draining = false;
  }

  /// What a command whose authority was withdrawn while it ran is reported
  /// as. A failure stays what it was; a success becomes `session_not_active`,
  /// because nothing can tell a gesture finished before the revocation from
  /// one Android finished in the race with its cancellation.
  RemoteControlAck _afterRevocation(
    RemoteControlCommand command,
    RemoteControlAck ack,
  ) {
    if (!ack.ok) return ack;
    _log(
      '${command.id} answered done after its authority was withdrawn: '
      'reported not done (outcome unknown by race)',
    );
    return RemoteControlAck.failure(
      command.id,
      RemoteControlError.sessionNotActive,
    );
  }

  Future<RemoteControlAck> _execute(RemoteControlCommand command) async {
    final error = await switch (command) {
      RemoteTapCommand(:final x, :final y) => _gesture(
        _accessibility.tap(x, y),
      ),
      RemoteLongPressCommand(:final x, :final y) => _gesture(
        _accessibility.longPress(x, y),
      ),
      RemoteSwipeCommand(
        :final startX,
        :final startY,
        :final endX,
        :final endY,
        :final durationMs,
      ) =>
        _gesture(
          _accessibility.swipe(
            startX: startX,
            startY: startY,
            endX: endX,
            endY: endY,
            durationMs: durationMs,
          ),
        ),
      RemoteBackCommand() => _gesture(_accessibility.performBack()),
      RemoteHomeCommand() => _gesture(_accessibility.performHome()),
      RemoteRecentsCommand() => _gesture(_accessibility.performRecents()),
      RemoteSetTextCommand(:final text) => _setText(
        _accessibility.performSetText(text),
      ),
      RemoteImeEnterCommand() => _imeEnter(_accessibility.performImeEnter()),
      // Never here: a hold is run by [touches] in [_drain], and what follows
      // a hold is refused by [submit].
      RemoteTouchCommand() => Future.value(RemoteControlError.gestureRejected),
    };
    return error == null
        ? RemoteControlAck.success(command.id)
        : RemoteControlAck.failure(command.id, error);
  }

  Future<RemoteControlError?> _gesture(
    Future<RemoteGestureOutcome> running,
  ) async => switch (await running) {
    RemoteGestureOutcome.completed => null,
    RemoteGestureOutcome.rejected => RemoteControlError.gestureRejected,
    RemoteGestureOutcome.unavailable =>
      RemoteControlError.accessibilityUnavailable,
    RemoteGestureOutcome.revoked => RemoteControlError.sessionNotActive,
  };

  Future<RemoteControlError?> _setText(
    Future<RemoteTextOutcome> running,
  ) async => switch (await running) {
    RemoteTextOutcome.completed => null,
    RemoteTextOutcome.targetUnavailable =>
      RemoteControlError.textTargetUnavailable,
    RemoteTextOutcome.rejected => RemoteControlError.textRejected,
    RemoteTextOutcome.unavailable =>
      RemoteControlError.accessibilityUnavailable,
    RemoteTextOutcome.revoked => RemoteControlError.sessionNotActive,
  };

  Future<RemoteControlError?> _imeEnter(
    Future<RemoteImeEnterOutcome> running,
  ) async => switch (await running) {
    RemoteImeEnterOutcome.completed => null,
    RemoteImeEnterOutcome.targetUnavailable =>
      RemoteControlError.textTargetUnavailable,
    RemoteImeEnterOutcome.actionUnavailable =>
      RemoteControlError.imeActionUnavailable,
    RemoteImeEnterOutcome.rejected => RemoteControlError.imeActionRejected,
    RemoteImeEnterOutcome.unavailable =>
      RemoteControlError.accessibilityUnavailable,
    RemoteImeEnterOutcome.revoked => RemoteControlError.sessionNotActive,
  };
}

void _silent(String _) {}

class _Pending {
  const _Pending(this.command, this.onAck);

  final RemoteControlCommand command;
  final void Function(RemoteControlAck ack) onAck;
}
