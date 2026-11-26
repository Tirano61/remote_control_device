/// Time elapsed since an arbitrary fixed origin, never going backwards.
///
/// Used where the age of something matters and the wall clock must not: a
/// user changing the date, NTP stepping the clock or a time-zone change cannot
/// make a measured interval shorter. Tests replace it with a value they move
/// by hand, together with the [TimerFactory] of the class under test.
typedef MonotonicClock = Duration Function();

final Stopwatch _process = Stopwatch()..start();

/// The real thing: a [Stopwatch] started with the process.
///
/// On Android the Dart VM reads `CLOCK_MONOTONIC`, which does not advance
/// while the device is in deep sleep (Dart timers use the same clock). Code
/// that must also count a sleep pairs it with the wall clock; see
/// `HeartbeatWatchdog`.
Duration systemMonotonicClock() => _process.elapsed;
