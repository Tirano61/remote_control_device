import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/screen_capture/data/flutter_webrtc_screen_media.dart';
import 'package:remote_control_device/features/screen_capture/data/method_channel_media_projection_service.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_transmission.dart';

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

    const evidence = ScreenTransmissionEvidence(
      channel: 4,
      observedAtNanos: 123456789012345,
      validFor: Duration(seconds: 13),
    );

    test('opens under a lease and closes its gate, by its own id', () async {
      reply = (call) => call.method == 'startScreenCapture'
          ? started('track-a')
          : {'applied': true, 'live': true};
      final capture = await source.open();
      calls.clear();

      expect(
        await capture.openTransmission(grant: 7, evidence: evidence),
        isTrue,
      );
      await capture.closeTransmission();

      expect(calls.map((call) => call.method), [
        'setScreenCaptureTransmission',
        'setScreenCaptureTransmission',
      ]);
      expect(calls.map((call) => call.arguments), [
        {
          'trackId': 'track-a',
          'transmitting': true,
          'grant': 7,
          'evidenceAtNanos': 123456789012345,
          'validForMs': 13000,
        },
        {'trackId': 'track-a', 'transmitting': false},
      ]);
    });

    test('an opening that is not live, or not applied, answers false', () async {
      final capture = await () async {
        reply = (call) => started('track-a');
        return source.open();
      }();
      reply = (call) => {'applied': true, 'live': false};
      expect(
        await capture.openTransmission(grant: 1, evidence: evidence),
        isFalse,
      );
      reply = (call) => {'applied': false, 'live': false};
      expect(
        await capture.openTransmission(grant: 2, evidence: evidence),
        isFalse,
      );
      reply = (call) => null;
      expect(
        await capture.openTransmission(grant: 3, evidence: evidence),
        isFalse,
      );
    });

    test('renews by its own id and reads every answer', () async {
      reply = (call) => started('track-a');
      final capture = await source.open();
      calls.clear();

      Future<ScreenLeaseRenewalAnswer> renewWith(Object? answer) {
        reply = (call) => answer;
        return capture.renewTransmission(grant: 7, evidence: evidence);
      }

      expect(
        await renewWith({'result': 'renewed', 'live': true}),
        const ScreenLeaseRenewalAnswer(
          ScreenLeaseRenewalResult.renewed,
          live: true,
        ),
      );
      expect(
        (await renewWith({'result': 'ignored', 'live': false})).result,
        ScreenLeaseRenewalResult.ignored,
      );
      expect(
        (await renewWith({'result': 'rejected', 'live': true})).result,
        ScreenLeaseRenewalResult.rejected,
      );
      expect(
        (await renewWith({'result': 'lapsed', 'live': false})).result,
        ScreenLeaseRenewalResult.lapsed,
      );
      // An answer this side cannot read is a lapse: the safe reading.
      expect(
        (await renewWith({'result': 'what'})).result,
        ScreenLeaseRenewalResult.lapsed,
      );
      expect(
        (await renewWith(null)).result,
        ScreenLeaseRenewalResult.lapsed,
      );
      expect(calls.first.method, 'renewScreenCaptureTransmission');
      expect(calls.first.arguments, {
        'trackId': 'track-a',
        'grant': 7,
        'evidenceAtNanos': 123456789012345,
        'validForMs': 13000,
      });
    });

    test('a gate the platform could not change reaches the caller', () async {
      reply = (call) => started('track-a');
      final capture = await source.open();
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'SCREEN_CAPTURE_TRANSMISSION_FAILED');
      });

      await expectLater(
        capture.closeTransmission(),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        capture.renewTransmission(grant: 1, evidence: evidence),
        throwsA(isA<PlatformException>()),
      );
    });

    test('a released capture sends nothing more', () async {
      reply = (call) => started('track-a');
      final capture = await source.open();
      await capture.dispose();
      calls.clear();

      expect(
        await capture.openTransmission(grant: 1, evidence: evidence),
        isFalse,
      );
      await capture.closeTransmission();
      expect(
        (await capture.renewTransmission(grant: 1, evidence: evidence)).result,
        ScreenLeaseRenewalResult.ignored,
      );

      expect(calls, isEmpty);
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

  group('Android ending the capture (MediaProjection onStop)', () {
    const source = FlutterWebRtcScreenMediaSource();

    /// What `MediaProjectionChannel.onStoppedByPlatform` sends.
    Future<void> androidStopped(String trackId) async {
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          MethodCall(FlutterWebRtcScreenMediaSource.stoppedByPlatformMethod, {
            'trackId': trackId,
          }),
        ),
        (_) {},
      );
    }

    test('reaches the capture it names, once', () async {
      reply = (call) => {'trackId': 'track-p'};
      final capture = await source.open();
      var ended = 0;
      capture.onEnded = () => ended++;

      await androidStopped('track-p');
      await androidStopped('track-p');

      expect(ended, 1);
    });

    test('a notice for another capture reaches nothing', () async {
      reply = (call) => {'trackId': 'track-q'};
      final capture = await source.open();
      var ended = 0;
      capture.onEnded = () => ended++;

      await androidStopped('track-old');

      expect(ended, 0);
      await capture.dispose();
    });

    test('a capture this application released is not reported', () async {
      reply = (call) => {'trackId': 'track-r'};
      final capture = await source.open();
      var ended = 0;
      capture.onEnded = () => ended++;
      await capture.dispose();

      await androidStopped('track-r');

      expect(ended, 0);
    });
  });
}
