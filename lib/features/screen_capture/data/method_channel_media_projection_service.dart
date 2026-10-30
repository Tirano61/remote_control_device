import 'package:flutter/services.dart';
import 'package:remote_control_device/features/screen_capture/domain/screen_capture_platform.dart';

/// The Flutter side of the bridge to `MediaProjectionForegroundService.kt`.
///
/// Two messages, no state and no policy. Whether the service *should* be
/// running is decided in `MediaProjectionScreenCaptureClient`; whether it
/// already is, is decided on the Android side, where the answer actually
/// lives. Making this class clever would mean two places believing different
/// things about one service.
///
/// [start] is answered by Android when the service is foreground as
/// `mediaProjection` — from `onStartCommand`, after `startForeground` returned —
/// and not when `startForegroundService` returned. The two are different
/// moments, and a capture opened between them is refused natively with a
/// `SecurityException`; that race was seen on a tablet. So awaiting [start] is
/// waiting for READY, and nothing here or above it sleeps instead.
///
/// Both calls are idempotent by consequence rather than by a flag here:
/// starting a service that is already running re-enters `onStartCommand` and
/// answers READY again, and stopping one that is not running is a no-op in
/// `Context.stopService`. Stopping also fails a start still waiting for its
/// answer, so one session's start can never be answered into the next. A
/// platform failure surfaces as a thrown [PlatformException] — the caller is
/// expected to catch it and carry on without the screen, which is exactly what
/// the client does.
class MethodChannelMediaProjectionForegroundService
    implements MediaProjectionForegroundService {
  const MethodChannelMediaProjectionForegroundService();

  /// Namespaced by application, not by plugin: this is a service belonging to
  /// this app, not a reusable Flutter plugin.
  static const MethodChannel channel = MethodChannel(
    'remote_control_device/media_projection',
  );

  static const String startMethod = 'startMediaProjectionForegroundService';
  static const String stopMethod = 'stopMediaProjectionForegroundService';

  @override
  Future<void> start() => channel.invokeMethod<void>(startMethod);

  @override
  Future<void> stop() => channel.invokeMethod<void>(stopMethod);
}

/// Android's screen capture consent dialog, over the same bridge.
///
/// The dialog is shown by `MainActivity` and the grant it produces stays on
/// the Android side, held for exactly one capture: it is a projection token
/// and it never crosses this channel. What crosses is the user's answer.
///
/// On Android 14 and later the dialog offers the whole display only — no
/// "share one app" option. A technician walking someone through their tablet
/// needs the device, and a single-app share goes black the moment the user
/// leaves that app, which reads as a broken session rather than as a choice.
class MethodChannelScreenCaptureConsent implements ScreenCaptureConsent {
  const MethodChannelScreenCaptureConsent();

  static const String consentMethod = 'requestScreenCaptureConsent';

  @override
  Future<bool> request() async {
    final granted = await MethodChannelMediaProjectionForegroundService.channel
        .invokeMethod<bool>(consentMethod);
    return granted ?? false;
  }
}
