/// Nanoseconds since the device booted, counting deep sleep: Android's
/// `SystemClock.elapsedRealtimeNanos()`, which is the kernel's
/// `CLOCK_BOOTTIME`.
///
/// It exists for one purpose: stamping an instant in Dart that the Android
/// side can compare with its own clock *as it was read*. The screen's
/// transmission lease is kept natively (`ScreenCaptureTransmission.kt`) and
/// runs out from the moment the heartbeat evidence was observed here, not from
/// the moment a message about it reached Kotlin; that is only possible when both
/// sides read the same clock. Dart's own `Stopwatch` is `CLOCK_MONOTONIC`,
/// which stops in deep sleep and has another origin, so it cannot be that
/// clock.
///
/// Tests replace it with a value they move by hand; see the implementation in
/// `android_elapsed_realtime_clock.dart`.
typedef ElapsedRealtimeClock = int Function();
