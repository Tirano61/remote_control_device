import 'package:equatable/equatable.dart';

/// One piece of heartbeat evidence of the `/devices` connection, as the native
/// screen transmission lease needs it.
///
/// ```text
/// watch             the connection it was observed on (HeartbeatWatchdog.watch)
/// observedAtNanos   when this isolate observed it, on the elapsed-realtime
///                   clock (CLOCK_BOOTTIME, Android's elapsedRealtimeNanos)
/// validFor          how long it vouches for: pingInterval + min(3 s, pingTimeout)
/// ```
///
/// It is the instant of the evidence and nothing else: a message carrying it
/// later carries the same instant, so it buys no time on the Android side.
final class HeartbeatEvidence extends Equatable {
  const HeartbeatEvidence({
    required this.watch,
    required this.observedAtNanos,
    required this.validFor,
  });

  final int watch;
  final int observedAtNanos;
  final Duration validFor;

  @override
  List<Object?> get props => [watch, observedAtNanos, validFor];
}

/// Where the screen's transmission lease gets its evidence from.
///
/// It grants nothing. Evidence only keeps alive a lease that an opening made
/// for a confirmed authority; it never opens one. In particular, the PING that
/// ends an overdue heartbeat, or one that comes after a gap nobody saw (the
/// isolate was held), is *not* published here: it starts a new chain of
/// evidence, and the authority has to be confirmed again before a new opening
/// can use it.
abstract interface class HeartbeatEvidenceSource {
  /// The newest evidence of an unbroken chain on the watched connection, or
  /// `null` when there is none: no connection, an overdue heartbeat, a
  /// connection whose heartbeat is not watched, or no elapsed-realtime clock.
  HeartbeatEvidence? get currentEvidence;

  /// Every PING that continues the chain: the evidence a running lease is
  /// renewed with.
  Stream<HeartbeatEvidence> get evidence;

  /// The Android side found that a lease given evidence of [watch] observed at
  /// [observedAtNanos] had already run out: the chain broke there, whatever
  /// the watchdog's own timers say. Declared overdue — the same suspension, the
  /// same REST confirmation before anything is sent again — unless the
  /// watchdog already knows of a break at or after that evidence.
  void reportLapse({required int watch, required int observedAtNanos});
}
