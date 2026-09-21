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
/// Both calls are idempotent by consequence rather than by a flag here:
/// starting a service that is already running re-enters `onStartCommand` and
/// changes nothing, and stopping one that is not running is a no-op in
/// `Context.stopService`. A platform failure surfaces as a thrown
/// [PlatformException] — the caller is expected to catch it and carry on
/// without the screen, which is exactly what the client does.
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
