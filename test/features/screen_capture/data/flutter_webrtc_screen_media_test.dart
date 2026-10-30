import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/screen_capture/data/flutter_webrtc_screen_media.dart';
import 'package:remote_control_device/features/screen_capture/data/method_channel_media_projection_service.dart';

/// The capture and consent adapters, from the Dart side of the wire.
///
/// What a host test can check is the conversation with `MediaProjectionChannel`:
/// which messages, with what, and what comes back. Whether the frames are the
/// right way up is the Android side's, tested on the JVM
/// (`ScreenCaptureGeometryTest`) and on the tablet.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final channel = MethodChannelMediaProjectionForegroundService.channel;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Object? Function(MethodCall call) reply;

  setUp(() {
    calls = [];
    reply = (_) => null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('consent', () {
    const consent = MethodChannelScreenCaptureConsent();

    test('asks the Android side and returns what the user chose', () async {
      reply = (_) => true;
      expect(await consent.request(), isTrue);

      reply = (_) => false;
      expect(await consent.request(), isFalse);

      expect(calls.map((call) => call.method), [
        'requestScreenCaptureConsent',
        'requestScreenCaptureConsent',
      ]);
    });

    test('a dialog that cannot be shown reaches the caller', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'SCREEN_CAPTURE_CONSENT_FAILED');
      });

      await expectLater(consent.request(), throwsA(isA<PlatformException>()));
    });
  });

  group('the capture', () {
    const source = FlutterWebRtcScreenMediaSource();

    Map<String, Object?> started(String trackId) => {
      'trackId': trackId,
      'displayWidth': 1280,
      'displayHeight': 800,
      'densityDpi': 160,
      'orientation': 'landscape',
      'rotation': 90,
      'virtualDisplaySide': 1280,
      'captureWidth': 1280,
      'captureHeight': 800,
    };

    test('opens one video track, the one Android registered', () async {
      reply = (call) => started('track-a');

      final capture = await source.open();

      expect(calls.single.method, 'startScreenCapture');
      expect(capture.videoTracks.map((track) => track.id), ['track-a']);
      final track = capture.videoTracks.single as FlutterWebRtcScreenVideoTrack;
      expect(track.track.kind, 'video');
    });

    test('releases it by its own id, once', () async {
      reply = (call) =>
          call.method == 'startScreenCapture' ? started('track-a') : null;
      final capture = await source.open();
      calls.clear();

      await capture.dispose();
      await capture.dispose();

      // Keyed, so that a late release of this capture cannot stop the one
      // that replaced it; and once, because every teardown path calls it.
      expect(calls, hasLength(1));
      expect(calls.single.method, 'stopScreenCapture');
      expect(calls.single.arguments, {'trackId': 'track-a'});
    });

    test('a capture that failed natively reaches the caller', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'SCREEN_CAPTURE_FAILED');
      });

      await expectLater(source.open(), throwsA(isA<PlatformException>()));
    });

    test('a capture without a track is released and refused', () async {
      reply = (call) => call.method == 'startScreenCapture'
          ? <String, Object?>{'displayWidth': 800}
          : null;

      await expectLater(source.open(), throwsA(isA<StateError>()));
      expect(calls.map((call) => call.method), [
        'startScreenCapture',
        'stopScreenCapture',
      ]);
    });

    test('releasing never throws', () async {
      reply = (call) => started('track-a');
      final capture = await source.open();
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'GONE');
      });

      await capture.dispose();
    });
  });
}
