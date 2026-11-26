import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart' show calloc;
import 'package:remote_control_device/core/async/elapsed_realtime_clock.dart';

/// `struct timespec` of the Android C library. Both fields are `long` on every
/// Android ABI (`time_t` is `long` there), which `Long` follows: 32 bits on
/// armeabi-v7a and x86, 64 on arm64-v8a and x86_64.
final class _Timespec extends Struct {
  @Long()
  external int seconds;

  @Long()
  external int nanoseconds;
}

typedef _ClockGettimeNative = Int32 Function(Int32 clock, Pointer<_Timespec>);
typedef _ClockGettime = int Function(int clock, Pointer<_Timespec>);

/// `CLOCK_BOOTTIME` in `<linux/time.h>`. The clock behind
/// `SystemClock.elapsedRealtimeNanos()` (libutils `elapsedRealtimeNano`).
const int _clockBoottime = 7;

/// The elapsed-realtime clock of this Android device, read through the C
/// library's `clock_gettime` — the same call, on the same clock, that
/// `SystemClock.elapsedRealtimeNanos()` makes on the Kotlin side. A synchronous
/// call on the isolate's own thread: the instant is the instant it was read,
/// with no channel in between.
///
/// `null` off Android, or when the call cannot be made or fails. A caller
/// without the clock has no lease to offer, and the screen is then never
/// transmitted: the native gate opens only with one.
ElapsedRealtimeClock? androidElapsedRealtimeClock() {
  if (!Platform.isAndroid) return null;
  try {
    final clockGettime = DynamicLibrary.open('libc.so')
        .lookupFunction<_ClockGettimeNative, _ClockGettime>(
          'clock_gettime',
          isLeaf: true,
        );
    // One buffer for the life of the process, read and overwritten on the
    // isolate's thread only.
    final buffer = calloc<_Timespec>();
    int read() {
      if (clockGettime(_clockBoottime, buffer) != 0) {
        throw StateError('clock_gettime(CLOCK_BOOTTIME) failed');
      }
      final time = buffer.ref;
      return time.seconds * 1000000000 + time.nanoseconds;
    }

    read();
    return read;
  } catch (_) {
    return null;
  }
}
