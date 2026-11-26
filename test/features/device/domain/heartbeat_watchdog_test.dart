import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/device/domain/realtime/heartbeat_watchdog.dart';
import 'package:remote_control_device/features/device/domain/realtime/realtime_heartbeat_policy.dart';

import '../../../fakes/manual_timers.dart';

/// The backend's heartbeat (REALTIME.md, "Heartbeat"): 10 s / 10 s.
const RealtimeHeartbeatPolicy policy1010 = RealtimeHeartbeatPolicy(
  pingInterval: Duration(seconds: 10),
  pingTimeout: Duration(seconds: 10),
);

/// Socket.IO's own defaults, which the backend used before its Prompt 36.
const RealtimeHeartbeatPolicy policy2520 = RealtimeHeartbeatPolicy(
  pingInterval: Duration(seconds: 25),
  pingTimeout: Duration(seconds: 20),
);

Duration ms(int value) => Duration(milliseconds: value);
Duration s(num value) => Duration(milliseconds: (value * 1000).round());

void main() {
  late ManualTimers timers;

  /// The wall clock: the manual clock plus whatever the test makes the device
  /// clock do on top of it (jumps, deep sleep).
  late Duration wallOffset;

  /// Deep sleep: the monotonic clock stops, the wall clock does not.
  late Duration monotonicLag;

  /// A busy isolate: both clocks run ahead of the timers, which fire late by
  /// this much.
  late Duration timersLate;

  late HeartbeatWatchdog watchdog;
  late List<String> events;

  setUp(() {
    timers = ManualTimers();
    wallOffset = Duration.zero;
    monotonicLag = Duration.zero;
    timersLate = Duration.zero;
    events = [];
    watchdog = HeartbeatWatchdog(
      timerFactory: timers.factory,
      monotonicClock: () => timers.now + timersLate - monotonicLag,
      wallClock: () => DateTime.utc(
        2026,
        11,
        26,
        12,
      ).add(timers.now + timersLate + wallOffset),
    );
  });

  void start([RealtimeHeartbeatPolicy? policy = policy1010]) {
    watchdog.start(
      policy,
      onOverdue: (watch) => events.add('overdue#$watch'),
      onStalled: (watch) => events.add('stalled#$watch'),
    );
  }

  group('policy', () {
    test('1. the 10/10 handshake gives 13 s overdue and 25 s stalled', () {
      final read = RealtimeHeartbeatPolicy.fromHandshake(
        pingIntervalMs: 10000,
        pingTimeoutMs: 10000,
      );
      expect(read, policy1010);
      expect(watchdog.thresholdFor(read!), s(13));
      expect(watchdog.stallDeadlineFor(read), s(25));
    });

    test('a missing or malformed handshake value gives no policy', () {
      for (final (interval, timeout) in <(Object?, Object?)>[
        (null, 10000),
        (10000, null),
        ('10000', 10000),
        (0, 10000),
        (10000, -1),
        (10.5, 10000),
      ]) {
        expect(
          RealtimeHeartbeatPolicy.fromHandshake(
            pingIntervalMs: interval,
            pingTimeoutMs: timeout,
          ),
          isNull,
          reason: '$interval / $timeout',
        );
      }
    });

    test('the tolerance follows the announced interval and never exceeds '
        'the timeout', () {
      expect(watchdog.thresholdFor(policy2520), s(28));
      const short = RealtimeHeartbeatPolicy(
        pingInterval: Duration(seconds: 10),
        pingTimeout: Duration(seconds: 2),
      );
      expect(watchdog.thresholdFor(short), s(12));
    });
  });

  group('deadline', () {
    test('2. a PING every 10 s plus a round trip: never overdue', () {
      start();
      for (var i = 0; i < 60; i++) {
        timers.elapse(ms(10000 + (i % 7) * 400)); // up to 2.4 s late
        expect(watchdog.beat(), isNotNull);
      }
      expect(events, isEmpty);
      expect(watchdog.isOverdue, isFalse);
      expect(watchdog.confirmFresh(), isTrue);
      // Never more than one timer, and it is not periodic.
      expect(timers.pending, hasLength(1));
    });

    test('3. the first PING, 12.9 s after the connection, is still in time',
        () {
      start();
      timers.elapse(ms(12900));
      expect(watchdog.beat(), ms(12900));
      timers.elapse(ms(12999));
      expect(events, isEmpty);
    });

    test('4-5. no PING: overdue at exactly 13 s, not a millisecond before',
        () {
      start();
      timers.elapse(ms(12999));
      expect(events, isEmpty);
      expect(watchdog.confirmFresh(), isTrue);
      timers.elapse(ms(1));
      expect(events, ['overdue#${watchdog.watch}']);
      expect(watchdog.isOverdue, isTrue);
      expect(watchdog.confirmFresh(), isFalse);
      expect(watchdog.evidenceAge, s(13));
    });

    test('measured from the last PING, not from the connection', () {
      start();
      timers.elapse(s(9));
      watchdog.beat();
      timers.elapse(ms(12999));
      expect(events, isEmpty);
      timers.elapse(ms(1));
      expect(events, hasLength(1));
      expect(timers.now, s(22));
    });

    test('a PING that came during the extra turn is counted', () {
      start();
      timers.elapse(ms(12999));
      // The deadline check alone: it finds the evidence 13 s old and gives
      // the isolate one more turn instead of deciding.
      timers.fireNext();
      expect(timers.now, s(13));
      expect(events, isEmpty);
      expect(timers.pending.single.dueAt, s(13), reason: 'the extra turn');
      // A PING that was already waiting behind the timer is handled first.
      watchdog.beat();
      timers.elapse(Duration.zero);
      expect(events, isEmpty);
      expect(watchdog.isOverdue, isFalse);
      // And the deadline starts over from it.
      timers.elapse(ms(12999));
      expect(events, isEmpty);
      timers.elapse(ms(1));
      expect(events, hasLength(1));
    });

    test('25 s without a PING: stalled, once', () {
      start();
      timers.elapse(s(25) - ms(1));
      expect(events, ['overdue#${watchdog.watch}']);
      timers.elapse(ms(1));
      expect(events, [
        'overdue#${watchdog.watch}',
        'stalled#${watchdog.watch}',
      ]);
      timers.elapse(s(60));
      expect(events, hasLength(2));
    });
  });

  group('after an overdue', () {
    test('a PING makes it fresh and the deadline starts over from it', () {
      start();
      timers.elapse(s(15));
      expect(watchdog.isOverdue, isTrue);
      expect(watchdog.beat(), s(15));
      expect(watchdog.isOverdue, isFalse);
      expect(watchdog.confirmFresh(), isTrue);
      timers.elapse(ms(12999));
      expect(events, hasLength(1));
      timers.elapse(ms(1));
      expect(events, hasLength(2), reason: 'a second overdue');
      expect(events.toSet(), hasLength(1), reason: 'same watch');
    });

    test('two suspensions and two recoveries in a row', () {
      start();
      for (var i = 0; i < 2; i++) {
        timers.elapse(s(14));
        expect(watchdog.isOverdue, isTrue);
        watchdog.beat();
        expect(watchdog.isOverdue, isFalse);
      }
      expect(events, hasLength(2));
      expect(timers.pending, hasLength(1));
    });
  });

  group('watches', () {
    test('8-9. a timer of the previous connection does nothing for the new '
        'one', () {
      start();
      final first = watchdog.watch;
      timers.elapse(s(12));
      start(); // a new connection: its evidence is now
      expect(watchdog.watch, greaterThan(first));
      timers.elapse(s(12));
      expect(events, isEmpty, reason: 'the old deadline was at 13 s');
      timers.elapse(s(1));
      expect(events, ['overdue#${watchdog.watch}']);
    });

    test('stop: nothing fires, nothing is fresh, a PING is ignored', () {
      start();
      watchdog.stop();
      expect(watchdog.confirmFresh(), isFalse);
      expect(watchdog.beat(), isNull);
      timers.elapse(s(60));
      expect(events, isEmpty);
      expect(timers.pending, isEmpty);
    });

    test('stop while overdue: the stall is never reported', () {
      start();
      timers.elapse(s(14));
      watchdog.stop();
      timers.elapse(s(60));
      expect(events, hasLength(1));
    });

    test('a connection without a policy is not watched', () {
      start(null);
      expect(watchdog.confirmFresh(), isTrue);
      expect(watchdog.beat(), isNull);
      timers.elapse(s(300));
      expect(events, isEmpty);
      expect(timers.pending, isEmpty);
    });
  });

  group('late execution and sleep', () {
    test('29. a timer that runs late decides from the real age, and a '
        'command checked before it ran is already refused', () {
      start();
      timers.elapse(s(10));
      // The isolate is blocked for 7 s: the clocks move, no timer runs.
      timersLate = s(7);
      expect(watchdog.evidenceAge, s(17));
      expect(watchdog.confirmFresh(), isFalse);
      timers.elapse(Duration.zero);
      expect(events, ['overdue#${watchdog.watch}']);
      expect(watchdog.evidenceAge, s(17));
    });

    test('29b. a late timer with a PING handled before it: nothing is '
        'declared, and the next deadline counts from that PING', () {
      start();
      timers.elapse(s(10));
      timersLate = s(7);
      watchdog.beat(); // real 17 s, handled before the 13 s timer
      timers.elapse(s(3)); // the timer runs (real 20 s): evidence 3 s old
      expect(events, isEmpty);
      timers.elapse(s(10) - ms(1)); // real 30 s - 1 ms: 13 s - 1 ms old
      expect(events, isEmpty);
      timers.elapse(ms(1));
      expect(events, hasLength(1));
    });

    test('28. deep sleep: the monotonic clock stood still, the wall clock '
        'did not; the next command finds the evidence stale', () {
      start();
      timers.elapse(s(5));
      // 10 s asleep: no timer ran, the monotonic clock did not move.
      wallOffset += s(10);
      expect(watchdog.confirmFresh(), isFalse);
      expect(events, isEmpty, reason: 'declared on the next turn');
      timers.elapse(Duration.zero);
      expect(events, ['overdue#${watchdog.watch}']);
    });

    test('28b. a sleep past the stall deadline reports both at once', () {
      start();
      timers.elapse(s(5));
      wallOffset += s(40);
      watchdog.checkNow();
      timers.elapse(Duration.zero);
      expect(events, [
        'overdue#${watchdog.watch}',
        'stalled#${watchdog.watch}',
      ]);
    });

    test('checkNow after the app comes back measures the real age', () {
      start();
      timers.elapse(s(2));
      wallOffset += s(30);
      watchdog.checkNow();
      timers.elapse(Duration.zero);
      expect(events.first, 'overdue#${watchdog.watch}');
    });

    test('the wall clock set back cannot make old evidence fresh', () {
      start();
      timers.elapse(s(10));
      wallOffset -= s(3600);
      timers.elapse(s(3));
      expect(events, ['overdue#${watchdog.watch}']);
    });

    test('the wall clock set forward makes it stale at once: the safe '
        'direction', () {
      start();
      timers.elapse(s(1));
      wallOffset += s(20);
      expect(watchdog.confirmFresh(), isFalse);
      timers.elapse(Duration.zero);
      expect(watchdog.isOverdue, isTrue);
    });

    test('deep sleep: the monotonic clock alone would have hidden it', () {
      start();
      timers.elapse(s(5));
      // The monotonic clock stands still for 40 s of sleep.
      monotonicLag = s(40);
      wallOffset = Duration.zero;
      timersLate = s(40);
      // monotonic: 5 s old; wall: 45 s old.
      expect(watchdog.evidenceAge, s(45));
      expect(watchdog.confirmFresh(), isFalse);
    });

    test('confirmFresh past the deadline refuses before the timer runs',
        () {
      start();
      // The check is due but has not run (the isolate is busy): only the
      // clock knows.
      wallOffset += s(13);
      expect(watchdog.confirmFresh(), isFalse);
      expect(watchdog.confirmFresh(), isFalse);
      timers.elapse(Duration.zero);
      expect(events, hasLength(1));
    });
  });
}
