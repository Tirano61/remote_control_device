import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/screen_capture/data/method_channel_media_projection_service.dart';

/// The bridge to `MediaProjectionForegroundService.kt`, from the Dart side.
///
/// What a host test can check is the wire: the channel name, the two method
/// names, and that a platform refusal reaches the caller as an error rather
/// than as silence. What it cannot check is the service itself — whether
/// Android accepted the `mediaProjection` type, whether the notification
/// appeared — and nothing here pretends otherwise. Those are verified on a
/// tablet and by the merged-manifest test next door.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const service = MethodChannelMediaProjectionForegroundService();
  final channel = MethodChannelMediaProjectionForegroundService.channel;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late bool platformFails;

  setUp(() {
    calls = [];
    platformFails = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (platformFails) {
        throw PlatformException(code: 'FOREGROUND_SERVICE_START_FAILED');
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('the channel is namespaced by application, not by plugin', () {
    // It carries a service belonging to this app; a plugin-shaped name would
    // suggest something reusable and collide with one that is.
    expect(channel.name, 'remote_control_device/media_projection');
  });

  test('start asks the platform to start the foreground service', () async {
    await service.start();

    expect(calls.single.method, 'startMediaProjectionForegroundService');
    expect(calls.single.arguments, isNull);
  });

  test('stop asks the platform to stop it', () async {
    await service.stop();

    expect(calls.single.method, 'stopMediaProjectionForegroundService');
  });

  test('repeated calls are forwarded and none of them throws', () async {
    // Idempotence lives on the Android side, where the answer actually is:
    // starting a running service re-enters onStartCommand and changes nothing,
    // and stopService on a service that is not running is a no-op. Holding a
    // second opinion here would mean two places believing different things
    // about one service.
    await service.start();
    await service.start();
    await service.stop();
    await service.stop();

    expect(calls.map((call) => call.method), [
      'startMediaProjectionForegroundService',
      'startMediaProjectionForegroundService',
      'stopMediaProjectionForegroundService',
      'stopMediaProjectionForegroundService',
    ]);
  });

  test('a platform refusal reaches the caller', () async {
    platformFails = true;

    // It has to be visible: Android can refuse a foreground service start, and
    // a bridge that swallowed that would let a capture begin without one —
    // which on Android 14 is a native SecurityException moments later.
    await expectLater(service.start(), throwsA(isA<PlatformException>()));
  });
}
