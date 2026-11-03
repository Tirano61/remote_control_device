import 'dart:collection';

import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';

/// Runs commands one at a time, in the order they were submitted.
///
/// The channel delivers them in order, but a gesture takes time, and a second
/// `dispatchGesture` would cancel the first. So the next command starts when
/// the previous one has finished.
///
/// It does not decide whether a command may run: the caller checks that before
/// submitting, and calls [discardPending] the moment the answer changes. A
/// gesture already running cannot be recalled, and is simply left to finish.
class RemoteControlCommandQueue {
  RemoteControlCommandQueue(this._accessibility);

  /// A browser that floods the channel gets refusals rather than taps that run
  /// long after anyone meant them.
  static const int maxPending = 16;

  final RemoteControlAccessibilityClient _accessibility;

  final Queue<_Pending> _pending = Queue<_Pending>();
  bool _draining = false;

  /// Queues [command]. [onAck] is called exactly once, with what became of it.
  void submit(
    RemoteControlCommand command,
    void Function(RemoteControlAck ack) onAck,
  ) {
    if (_pending.length >= maxPending) {
      onAck(
        RemoteControlAck.failure(
          command.id,
          RemoteControlError.gestureRejected,
        ),
      );
      return;
    }
    _pending.add(_Pending(command, onAck));
    _drain();
  }

  /// Drops everything that has not started. Each is answered as refused, since
  /// nothing will run it.
  void discardPending() {
    while (_pending.isNotEmpty) {
      final pending = _pending.removeFirst();
      pending.onAck(
        RemoteControlAck.failure(
          pending.command.id,
          RemoteControlError.sessionNotActive,
        ),
      );
    }
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    while (_pending.isNotEmpty) {
      final pending = _pending.removeFirst();
      pending.onAck(await _execute(pending.command));
    }
    _draining = false;
  }

  Future<RemoteControlAck> _execute(RemoteControlCommand command) async {
    final outcome = await switch (command) {
      RemoteTapCommand(:final x, :final y) => _accessibility.tap(x, y),
      RemoteSwipeCommand(
        :final startX,
        :final startY,
        :final endX,
        :final endY,
        :final durationMs,
      ) =>
        _accessibility.swipe(
          startX: startX,
          startY: startY,
          endX: endX,
          endY: endY,
          durationMs: durationMs,
        ),
      RemoteBackCommand() => _accessibility.performBack(),
      RemoteHomeCommand() => _accessibility.performHome(),
    };
    return switch (outcome) {
      RemoteGestureOutcome.completed => RemoteControlAck.success(command.id),
      RemoteGestureOutcome.rejected => RemoteControlAck.failure(
        command.id,
        RemoteControlError.gestureRejected,
      ),
      RemoteGestureOutcome.unavailable => RemoteControlAck.failure(
        command.id,
        RemoteControlError.accessibilityUnavailable,
      ),
    };
  }
}

class _Pending {
  const _Pending(this.command, this.onAck);

  final RemoteControlCommand command;
  final void Function(RemoteControlAck ack) onAck;
}
