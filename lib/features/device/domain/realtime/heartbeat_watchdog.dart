import 'dart:async';

import 'package:remote_control_device/core/async/elapsed_realtime_clock.dart';
import 'package:remote_control_device/core/async/monotonic_clock.dart';
import 'package:remote_control_device/core/async/timer_factory.dart';
import 'package:remote_control_device/features/device/domain/realtime/heartbeat_evidence.dart';
import 'package:remote_control_device/features/device/domain/realtime/realtime_heartbeat_policy.dart';
import 'package:remote_control_device/features/device/domain/realtime/realtime_liveness.dart';

/// What [HeartbeatWatchdog.beat] learnt from one PING.
final class HeartbeatBeat {
  const HeartbeatBeat({required this.gap, required this.afterUnseenLapse});

  /// How long it had been since the previous evidence.
  final Duration gap;

  /// The gap was already past the overdue deadline, and nothing had declared
  /// it: the watchdog's timer had not run (the isolate was held, the process
  /// slept). The heartbeat stopped vouching for the authority for a while, and
  /// that has to be treated as an overdue that is already over — a suspension
  /// and a REST confirmation — not as a heartbeat that never stopped.
  final bool afterUnseenLapse;
}

/// Watches the Engine.IO heartbeat of the current `/devices` connection and
/// says when it has gone quiet for longer than a healthy one can.
///
/// ## The evidence
///
/// Only two things count, both on the connection being watched:
///
/// ```text
/// the connection came up   (start)   the namespace accepted the handshake
/// an Engine.IO PING arrived (beat)    the server reached this tablet just now
/// ```
///
/// Nothing else does. An application event, an ACK, WebRTC traffic or a data
/// channel message proves nothing about `/devices`: the backend tells the
/// tablet that a session was closed over this socket alone, so this socket's
/// own heartbeat is what the authority hangs on.
///
/// ## The deadline
///
/// ```text
/// overdue   when no evidence for  pingInterval + min(tolerance, pingTimeout)
///                                 10 s + 3 s = 13 s with the backend's 10/10
/// stalled   when no evidence for  pingInterval + pingTimeout + stallMargin
///                                 10 s + 10 s + 5 s = 25 s
/// ```
///
/// The server sends the next `PING` [RealtimeHeartbeatPolicy.pingInterval]
/// after the previous `PONG` reached it, so on a healthy connection the gap
/// between two `PING`s seen here is the interval plus a round trip (and the
/// jitter of both). [tolerance] has to cover that; it never exceeds the
/// `pingTimeout`, past which the transport's own timeout (`pingInterval +
/// pingTimeout`, socket_io_client 3.1.6) would have decided anyway.
///
/// The first `PING` of a connection is due `pingInterval` after the Engine.IO
/// handshake, which happens before the namespace accepts the connection; the
/// watch starts at the later of the two, so the first gap is never longer than
/// any other.
///
/// Stalled is a backstop for a transport that never gives up on its own: by
/// then its own `ping timeout` should have closed the socket. The owner opens
/// a new one; see `DeviceRealtimeBloc`.
///
/// ## How the deadline is kept
///
/// There is never more than one timer, and it is not a periodic one. A beat
/// only records the moment ([MonotonicClock] and wall clock); the pending
/// check, when it fires, measures the age of the newest evidence and either
/// re-arms itself for the time that is left or decides. So a late timer
/// (a busy isolate, a process that slept) decides from the real age, never
/// from the fact that it ran, and a beat that came meanwhile moves nothing.
///
/// Before declaring overdue it gives the isolate one more turn (a zero-delay
/// timer, queued behind anything already delivered), so that a `PING` that
/// reached the tablet in time but was waiting behind the timer is counted.
///
/// ## Age
///
/// The larger of the monotonic and the wall-clock interval. The monotonic
/// clock alone stops while Android is in deep sleep, and the wall clock alone
/// can be set back. With both, sleeping cannot make evidence look fresh, and
/// setting the clock back cannot either; setting it forward can only make it
/// look stale, which suspends and reconciles — the safe direction.
///
/// ## Unseen lapses
///
/// A PING handled after a gap longer than the overdue deadline, with the
/// watchdog still *watching* — its timer never ran, because the isolate was
/// held or the process slept — is not a heartbeat that never stopped. Until
/// Prompt 43 it was taken as one, and nothing was suspended. Now [beat]
/// reports it ([HeartbeatBeat.afterUnseenLapse]) and the owner treats it as an
/// overdue that is already over: suspend, and confirm again over REST. The
/// native transmission lease ran out at the same deadline in the meantime,
/// without waiting for this isolate at all (see [HeartbeatEvidenceSource]).
///
/// ## Evidence for the native lease
///
/// With an [ElapsedRealtimeClock], every piece of evidence is also stamped on
/// Android's elapsed-realtime clock, and that instant is what the native
/// screen lease runs from ([currentEvidence], [evidence]). The age then also
/// counts that clock, so the watchdog never finds evidence younger than the
/// native side does. A chain of evidence starts with the connection, or with
/// the PING that ends an overdue or an unseen lapse; only the PINGs that
/// continue a chain are published as [evidence].
///
/// ## Watches
///
/// Every [start] and [stop] begins a new watch ([watch]). A timer of an older
/// watch does nothing, and the callbacks carry the watch that raised them, so
/// the owner can drop one that arrives after the connection was replaced. A
/// beat is only ever recorded for the watch that is running: a `PING` of a
/// released socket never reaches here (the transport drops it), and one
/// arriving while nothing is watched is ignored.
final class HeartbeatWatchdog
    implements RealtimeLiveness, HeartbeatEvidenceSource {
  HeartbeatWatchdog({
    this.tolerance = defaultTolerance,
    this.stallMargin = defaultStallMargin,
    TimerFactory timerFactory = systemTimerFactory,
    MonotonicClock monotonicClock = systemMonotonicClock,
    DateTime Function() wallClock = DateTime.now,
    ElapsedRealtimeClock? elapsedRealtimeClock,
  }) : assert(!tolerance.isNegative, 'the tolerance cannot be negative'),
       _timerFactory = timerFactory,
       _monotonic = monotonicClock,
       _wall = wallClock,
       _realtime = elapsedRealtimeClock;

  /// Allowed on top of `pingInterval` before the heartbeat counts as overdue.
  /// Covers the round trip the server waits for before scheduling the next
  /// `PING`, and its jitter. The value was measured on the T10A through the
  /// dev tunnel; see docs/remote_session/LIFECYCLE.md, "Heartbeat watchdog".
  static const Duration defaultTolerance = Duration(seconds: 3);

  /// Allowed on top of `pingInterval + pingTimeout` for the transport to give
  /// up by itself before a new socket replaces it.
  static const Duration defaultStallMargin = Duration(seconds: 5);

  final Duration tolerance;
  final Duration stallMargin;
  final TimerFactory _timerFactory;
  final MonotonicClock _monotonic;
  final DateTime Function() _wall;

  /// `null` without one: no evidence is offered to the native lease, and the
  /// screen is then never transmitted.
  final ElapsedRealtimeClock? _realtime;

  int _watch = 0;
  _Phase _phase = _Phase.stopped;
  RealtimeHeartbeatPolicy? _policy;
  Duration _evidenceMonotonic = Duration.zero;
  DateTime _evidenceWall = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  int? _evidenceRealtime;

  /// The elapsed-realtime instant the current chain of evidence started at.
  int? _chainStartRealtime;
  final StreamController<HeartbeatEvidence> _evidence =
      StreamController<HeartbeatEvidence>.broadcast();
  Timer? _timer;
  bool _settling = false;
  void Function(int watch)? _onOverdue;
  void Function(int watch)? _onStalled;

  /// The watch running now. Never decreases.
  int get watch => _watch;

  /// The policy of the connection being watched; `null` when none is.
  RealtimeHeartbeatPolicy? get policy => _policy;

  /// Whether the watched connection's heartbeat is overdue right now, as
  /// declared (not merely due: see [confirmFresh]).
  bool get isOverdue => _phase == _Phase.overdue;

  /// Age of the newest evidence, or `null` when nothing is watched.
  Duration? get evidenceAge => _policy == null ? null : _age();

  /// The overdue deadline for [policy].
  Duration thresholdFor(RealtimeHeartbeatPolicy policy) =>
      policy.pingInterval +
      (tolerance < policy.pingTimeout ? tolerance : policy.pingTimeout);

  /// The stalled deadline for [policy].
  Duration stallDeadlineFor(RealtimeHeartbeatPolicy policy) =>
      policy.pingInterval + policy.pingTimeout + stallMargin;

  /// A connection came up: watch it, with its coming up as the first
  /// evidence.
  ///
  /// Without a [policy] (the handshake values could not be read) the
  /// connection is not watched: [confirmFresh] answers `true` while it lasts
  /// and the transport's own timeout is the only one. With socket_io_client
  /// 3.1.6 the values are always there once the namespace has accepted the
  /// connection; the case exists so that a transport that stopped exposing
  /// them degrades to the behaviour before the watchdog, not to a tablet that
  /// suspends itself every few seconds.
  void start(
    RealtimeHeartbeatPolicy? policy, {
    required void Function(int watch) onOverdue,
    required void Function(int watch) onStalled,
  }) {
    stop();
    if (policy == null) {
      _phase = _Phase.unmonitored;
      return;
    }
    _policy = policy;
    _onOverdue = onOverdue;
    _onStalled = onStalled;
    _phase = _Phase.watching;
    _record();
    _chainStartRealtime = _evidenceRealtime;
    _arm(thresholdFor(policy));
  }

  /// An Engine.IO `PING` arrived on the watched connection.
  ///
  /// Returns how long it had been since the previous evidence (for the log)
  /// and whether that gap was an unseen lapse, or `null` when nothing is
  /// watched and the beat was ignored. After an overdue, or an unseen lapse,
  /// it makes the heartbeat fresh again — and that is all it does: it grants
  /// nothing, see `DeviceRealtimeBloc`.
  HeartbeatBeat? beat() {
    final policy = _policy;
    if (policy == null) return null;
    final gap = _age();
    final threshold = thresholdFor(policy);
    final wasOverdue = _phase == _Phase.overdue;
    final unseenLapse = _phase == _Phase.watching && gap >= threshold;
    _record();
    if (wasOverdue || unseenLapse) {
      // A new chain of evidence starts here. Not published: it vouches for
      // nothing until the authority is confirmed again.
      _phase = _Phase.watching;
      _settling = false;
      _chainStartRealtime = _evidenceRealtime;
      _arm(threshold);
    } else {
      // While watching, the pending check is left alone: it fires at the
      // deadline of the previous evidence, finds this one and re-arms from it.
      final evidence = currentEvidence;
      if (evidence != null) _evidence.add(evidence);
    }
    return HeartbeatBeat(gap: gap, afterUnseenLapse: unseenLapse);
  }

  /// Nothing to watch any more: the connection is gone or was replaced.
  void stop() {
    _watch++;
    _cancelTimer();
    _phase = _Phase.stopped;
    _policy = null;
    _settling = false;
    _onOverdue = null;
    _onStalled = null;
    _evidenceRealtime = null;
    _chainStartRealtime = null;
  }

  /// Re-evaluates now, from the clocks. For a tablet that may have slept: the
  /// application coming back to the foreground.
  void checkNow() {
    if (_phase == _Phase.watching || _phase == _Phase.overdue) _check(_watch);
  }

  @override
  bool confirmFresh() {
    switch (_phase) {
      case _Phase.stopped:
      case _Phase.overdue:
        return false;
      case _Phase.unmonitored:
        return true;
      case _Phase.watching:
        if (_age() < thresholdFor(_policy!)) return true;
        // Due, and the check has not run yet: late. The caller is refused at
        // once; the declaration follows the same path as the timer's.
        _settle();
        return false;
    }
  }

  @override
  HeartbeatEvidence? get currentEvidence {
    final policy = _policy;
    final observedAt = _evidenceRealtime;
    if (_phase != _Phase.watching || policy == null || observedAt == null) {
      return null;
    }
    return HeartbeatEvidence(
      watch: _watch,
      observedAtNanos: observedAt,
      validFor: thresholdFor(policy),
    );
  }

  @override
  Stream<HeartbeatEvidence> get evidence => _evidence.stream;

  @override
  void reportLapse({required int watch, required int observedAtNanos}) {
    if (watch != _watch || _phase != _Phase.watching) return;
    final chainStart = _chainStartRealtime;
    // Evidence older than the chain running now: the break it shows is one
    // the watchdog has already seen and declared.
    if (chainStart != null && observedAtNanos < chainStart) return;
    final policy = _policy!;
    _settling = false;
    _phase = _Phase.overdue;
    _arm(stallDeadlineFor(policy) - _age());
    _onOverdue?.call(watch);
  }

  // --------------------------------------------------------------- internals

  void _check(int watch) {
    if (watch != _watch) return;
    _timer = null;
    final policy = _policy;
    if (policy == null) return;
    final age = _age();

    switch (_phase) {
      case _Phase.watching:
        final threshold = thresholdFor(policy);
        if (age < threshold) {
          _settling = false;
          _arm(threshold - age);
          return;
        }
        if (!_settling) {
          _settle();
          return;
        }
        _settling = false;
        _phase = _Phase.overdue;
        _arm(stallDeadlineFor(policy) - age);
        _onOverdue?.call(watch);

      case _Phase.overdue:
        final stallDeadline = stallDeadlineFor(policy);
        if (age < stallDeadline) {
          _arm(stallDeadline - age);
          return;
        }
        // Reported once per watch: the owner replaces the connection, which
        // starts a new watch.
        final onStalled = _onStalled;
        _onStalled = null;
        onStalled?.call(watch);

      case _Phase.stopped:
      case _Phase.unmonitored:
        return;
    }
  }

  void _settle() {
    if (_settling) return;
    _settling = true;
    _arm(Duration.zero);
  }

  void _arm(Duration after) {
    _cancelTimer();
    final watch = _watch;
    _timer = _timerFactory(
      after.isNegative ? Duration.zero : after,
      () => _check(watch),
    );
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _record() {
    _evidenceMonotonic = _monotonic();
    _evidenceWall = _wall();
    _evidenceRealtime = _readRealtime();
  }

  int? _readRealtime() {
    final realtime = _realtime;
    if (realtime == null) return null;
    try {
      return realtime();
    } catch (_) {
      return null;
    }
  }

  Duration _age() {
    final monotonic = _monotonic() - _evidenceMonotonic;
    final wall = _wall().difference(_evidenceWall);
    var age = wall > monotonic ? wall : monotonic;
    final from = _evidenceRealtime;
    final now = from == null ? null : _readRealtime();
    if (from != null && now != null) {
      final realtime = Duration(microseconds: (now - from) ~/ 1000);
      if (realtime > age) age = realtime;
    }
    return age;
  }
}

enum _Phase {
  /// No connection.
  stopped,

  /// A connection without a readable policy: not watched.
  unmonitored,

  /// A connection whose heartbeat is fresh.
  watching,

  /// A connection whose heartbeat is overdue.
  overdue,
}
