import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/screen_capture/data/media_projection_screen_capture_client.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_capture_result.dart';

import '../../../fakes/screen_capture_fakes.dart';

/// Screen capture as a set of decisions, exercised without Android.
///
/// The one thing worth saying twice: the order these tests assert is not a
/// preference. Android 14 refuses a `mediaProjection` foreground service
/// started before the user consented, and refuses a capture started before the
/// service is up, and both refusals arrive as native exceptions. So the order
/// is the contract, and a list of calls in the order they were made is the
/// only honest way to assert it.
void main() {
  const otherSession = 'a3e0b1d2-0000-4000-8000-000000000002';
  const session = 'a3e0b1d2-0000-4000-8000-000000000001';

  late FakeScreenCapturePlatform platform;
  late MediaProjectionScreenCaptureClient client;

  setUp(() {
    platform = FakeScreenCapturePlatform();
    client = MediaProjectionScreenCaptureClient(
      consent: platform.consent,
      foregroundService: platform.foregroundService,
      mediaSource: platform.mediaSource,
    );
  });

  // ------------------------------------------------------------- the order

  group('the Android 14 order', () {
    test('is consent, then the foreground service, then the capture', () async {
      final result = await client.requestAndStart(session);

      expect(result, isA<ScreenCaptureStarted>());
      expect(platform.calls, [
        'consent.request',
        'foregroundService.start',
        'mediaSource.open',
      ]);
    });

    test(
      'never starts the foreground service before consent is given',
      () async {
        platform.granted = false;

        await client.requestAndStart(session);

        // Not "started and then stopped": never started at all. Android refuses
        // a mediaProjection service for an app with no projection, and a
        // notification saying the screen is shared would be a lie besides.
        expect(platform.calls, ['consent.request']);
      },
    );

    test(
      'never opens the capture before the foreground service is up',
      () async {
        platform.foregroundServiceStartThrows = true;

        await client.requestAndStart(session);

        expect(platform.calls, isNot(contains('mediaSource.open')));
      },
    );
  });

  // ------------------------------------------------------------- the answer

  group('what the user answered', () {
    test('a refusal is an answer, not a failure', () async {
      platform.granted = false;

      final result = await client.requestAndStart(session);

      expect(result, const ScreenCaptureDenied());
      expect(client.isActive, isFalse);
      expect(client.remoteSessionId, isNull);
    });

    test('a dialog that could not be shown is a failure', () async {
      platform.consentThrows = true;

      final result = await client.requestAndStart(session);

      expect(
        result,
        const ScreenCaptureUnavailable(ScreenCaptureFailure.consentUnavailable),
      );
      expect(platform.foregroundServiceRunning, isFalse);
    });

    test('acceptance yields the single video track and nothing else', () async {
      final result = await client.requestAndStart(session);

      expect(result, const ScreenCaptureStarted(testScreenVideoTrack));
      expect(client.isActive, isTrue);
      expect(client.remoteSessionId, session);
      // Video only. There is no audio track to hand back because none was ever
      // asked for -- the manifest has no RECORD_AUDIO either.
      expect(platform.lastCapture.videoTracks, [testScreenVideoTrack]);
    });
  });

  // ---------------------------------------------------------------- failure

  group('a start that failed', () {
    test(
      'leaves the foreground service stopped when the capture fails',
      () async {
        platform.captureThrows = true;

        final result = await client.requestAndStart(session);

        expect(
          result,
          const ScreenCaptureUnavailable(ScreenCaptureFailure.captureRefused),
        );
        expect(platform.calls, [
          'consent.request',
          'foregroundService.start',
          'mediaSource.open',
          'foregroundService.stop',
        ]);
        expect(platform.foregroundServiceRunning, isFalse);
        expect(client.isActive, isFalse);
      },
    );

    test('stops a service that threw on the way up', () async {
      platform.foregroundServiceStartThrows = true;

      final result = await client.requestAndStart(session);

      expect(
        result,
        const ScreenCaptureUnavailable(
          ScreenCaptureFailure.foregroundServiceRefused,
        ),
      );
      // A start that threw may still have got half-way. Asking it to stop
      // costs nothing and is the only way not to leave a notification behind.
      expect(platform.calls, [
        'consent.request',
        'foregroundService.start',
        'foregroundService.stop',
      ]);
    });

    test('refuses a capture with no video track, and releases it', () async {
      platform.nextVideoTracks = const [];

      final result = await client.requestAndStart(session);

      expect(
        result,
        const ScreenCaptureUnavailable(ScreenCaptureFailure.unexpectedTracks),
      );
      expect(platform.lastCapture.isDisposed, isTrue);
      expect(platform.foregroundServiceRunning, isFalse);
      expect(client.isActive, isFalse);
    });

    test('refuses a capture with more than one video track', () async {
      platform.nextVideoTracks = const [
        FakeScreenVideoTrack('one'),
        FakeScreenVideoTrack('two'),
      ];

      final result = await client.requestAndStart(session);

      // Nothing this side cannot account for is transmitted, and picking one
      // of two at random is exactly the kind of guess that ends up sending the
      // wrong thing.
      expect(
        result,
        const ScreenCaptureUnavailable(ScreenCaptureFailure.unexpectedTracks),
      );
      expect(platform.lastCapture.isDisposed, isTrue);
    });

    test('a failure never throws at the caller', () async {
      platform.captureThrows = true;

      // The caller is in the middle of answering a WebRTC offer. An exception
      // here would be an assistance session that never started because a
      // permission dialog misbehaved.
      await expectLater(client.requestAndStart(session), completes);
    });
  });

  // ------------------------------------------------------------------ reuse

  group('one capture per remote session', () {
    test('a second start for the same session asks the user nothing', () async {
      final first = await client.requestAndStart(session);
      platform.calls.clear();

      final second = await client.requestAndStart(session);

      // This is the "a new PeerConnection within one assistance session" case,
      // and the whole reason the client holds state: the user consented once.
      expect(second, first);
      expect(platform.calls, isEmpty);
      expect(platform.captures, hasLength(1));
    });

    test('two offers racing the same dialog produce one dialog', () async {
      platform.consentGate = Completer<void>();

      final first = client.requestAndStart(session);
      final second = client.requestAndStart(session);
      platform.consentGate!.complete();

      expect(await first, await second);
      expect(
        platform.calls.where((call) => call == 'consent.request'),
        hasLength(1),
      );
      expect(platform.captures, hasLength(1));
    });

    test(
      'a different session is a different capture, asked for again',
      () async {
        await client.requestAndStart(session);
        final firstCapture = platform.lastCapture;
        platform.calls.clear();

        final result = await client.requestAndStart(otherSession);

        expect(result, isA<ScreenCaptureStarted>());
        // The old one is released *before* the new consent is asked for: an
        // Android projection token is granted for one capture, and carrying one
        // into the next assistance session is what the platform stopped allowing
        // and what the user never agreed to.
        expect(firstCapture.isDisposed, isTrue);
        expect(platform.calls, [
          'capture.dispose',
          'foregroundService.stop',
          'consent.request',
          'foregroundService.start',
          'mediaSource.open',
        ]);
        expect(client.remoteSessionId, otherSession);
      },
    );

    test('a capture after a stop needs a new authorisation', () async {
      await client.requestAndStart(session);
      await client.stop();
      platform.calls.clear();

      await client.requestAndStart(session);

      expect(platform.calls, [
        'consent.request',
        'foregroundService.start',
        'mediaSource.open',
      ]);
      expect(platform.captures, hasLength(2));
    });
  });

  // ---------------------------------------------------------------- stopping

  group('stopping', () {
    test('releases the capture and takes the notification down', () async {
      await client.requestAndStart(session);
      platform.calls.clear();

      await client.stop();

      expect(platform.calls, ['capture.dispose', 'foregroundService.stop']);
      expect(client.isActive, isFalse);
      expect(client.remoteSessionId, isNull);
    });

    test('is idempotent', () async {
      await client.requestAndStart(session);
      await client.stop();
      platform.calls.clear();

      await client.stop();
      await client.stop();

      // Several paths lead to a stop -- the session closed by either end, a
      // revoked credential, the app shutting down -- and none of them can know
      // whether it is first.
      expect(platform.calls, isEmpty);
      expect(platform.lastCapture.disposeCount, 1);
    });

    test('on a client that never captured does nothing', () async {
      await client.stop();

      expect(platform.calls, isEmpty);
    });
  });

  // --------------------------------------------- the platform ending it

  group('when Android ends the capture', () {
    test('the client stops holding it', () async {
      await client.requestAndStart(session);
      expect(platform.lastCapture.isListened, isTrue);

      platform.lastCapture.endFromPlatform();
      await Future<void>.delayed(Duration.zero);

      // The user pressed "Stop sharing" in the system controls. Everything
      // this side held is released, and that is all: the remote session stays
      // open, the control channel stays open, and nothing renegotiates.
      expect(client.isActive, isFalse);
      expect(platform.foregroundServiceRunning, isFalse);
    });

    test('a teardown of ours is not mistaken for one of theirs', () async {
      await client.requestAndStart(session);
      final capture = platform.lastCapture;

      await client.stop();

      expect(capture.isListened, isFalse);
      expect(capture.disposeCount, 1);
    });
  });
}
