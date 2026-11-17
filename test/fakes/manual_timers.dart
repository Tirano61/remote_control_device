import 'dart:async';

import 'package:remote_control_device/core/async/timer_factory.dart';

/// A clock the test moves by hand.
///
/// Passed as the [TimerFactory] of the class under test, it records every
/// deadline that class sets and fires one only when [elapse] carries the
/// clock past it. Nothing depends on wall time, so a 45 s grace period is
/// tested in microseconds and exactly at its edges.
class ManualTimers {
  Duration _now = Duration.zero;
  final List<ManualTimer> _timers = [];

  Duration get now => _now;

  TimerFactory get factory => (duration, onFire) {
    final timer = ManualTimer._(this, _now + duration, onFire);
    _timers.add(timer);
    return timer;
  };

  /// Deadlines set and neither fired nor cancelled.
  List<ManualTimer> get pending =>
      _timers.where((timer) => timer.isActive).toList();

  /// Moves the clock forward and fires, in order, every deadline reached.
  void elapse(Duration duration) {
    final target = _now + duration;
    while (true) {
      final due = pending.where((timer) => timer.dueAt <= target).toList()
        ..sort((a, b) => a.dueAt.compareTo(b.dueAt));
      if (due.isEmpty) break;
      final timer = due.first;
      _now = timer.dueAt;
      timer._fire();
    }
    _now = target;
  }
}

class ManualTimer implements Timer {
  ManualTimer._(this._owner, this.dueAt, this._onFire);

  final ManualTimers _owner;
  final Duration dueAt;
  final void Function() _onFire;
  bool _active = true;

  void _fire() {
    if (!_active) return;
    _active = false;
    _onFire();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;

  @override
  String toString() =>
      'ManualTimer(due ${dueAt.inMilliseconds} ms, '
      'now ${_owner.now.inMilliseconds} ms, active $_active)';
}
