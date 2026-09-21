import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The parts of screen capture that live in files a Dart test can read, but a
/// Dart test can never execute.
///
/// A manifest is not decoration on Android 14. A `MediaProjection` capture
/// throws a `SecurityException` unless a running foreground service is
/// *declared* with `foregroundServiceType="mediaProjection"` and the app holds
/// `FOREGROUND_SERVICE_MEDIA_PROJECTION` — so a missing attribute is not a
/// warning at build time, it is a crash on a tablet during a support session.
/// So both manifests are read: the one written by hand, and — once
/// `flutter build apk --debug` has produced it — the merged one that actually
/// ships, which is the only place a plugin's own permissions become visible.
///
/// The second half is about what is *not* there. A remote-support application
/// that could quietly capture a camera or a microphone is a different product
/// from one that shares a screen, and the difference should be visible in the
/// permissions it asks for and enforced by something that fails.
void main() {
  late String manifest;

  setUpAll(() async {
    manifest = await File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsString();
  });

  group('the manifest Android 14 requires', () {
    test('declares both foreground-service permissions', () {
      expect(
        manifest,
        contains('android:name="android.permission.FOREGROUND_SERVICE"'),
      );
      expect(
        manifest,
        contains(
          'android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION"',
        ),
      );
    });

    test('declares the service, typed and not exported', () {
      // Read as one block so an `exported="true"` belonging to the activity
      // cannot be mistaken for this service's.
      final service = RegExp(
        r'<service[^>]*android:name="\.MediaProjectionForegroundService"[^>]*/>',
        dotAll: true,
      ).firstMatch(manifest)?.group(0);

      expect(service, isNotNull, reason: 'the service is not declared');
      expect(
        service,
        contains('android:foregroundServiceType="mediaProjection"'),
      );
      // Nothing outside this application may start a screen capture.
      expect(service, contains('android:exported="false"'));
    });

    test('keeps the permissions the device already needed', () {
      expect(manifest, contains('android:name="android.permission.INTERNET"'));
      expect(
        manifest,
        contains('android:name="android.permission.ACCESS_NETWORK_STATE"'),
      );
    });
  });

  group('the merged manifest', () {
    // Produced by `flutter build apk --debug`, and absent on a clean checkout.
    // It is the one that ships, and it is not the one written by hand: the
    // plugins merge their own permissions into it, so "we did not ask for the
    // microphone" is only true once it has been read here.
    final merged = File(
      'build/app/intermediates/merged_manifest/debug/'
      'processDebugMainManifest/AndroidManifest.xml',
    );

    test(
      'carries the service and its permissions',
      () async {
        final xml = await merged.readAsString();

        expect(
          xml,
          contains('android:name="android.permission.FOREGROUND_SERVICE"'),
        );
        expect(
          xml,
          contains(
            'android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION"',
          ),
        );
        expect(
          xml,
          contains('android:foregroundServiceType="mediaProjection"'),
        );
        expect(
          xml,
          contains(
            'android:name="com.example.remote_control_device.'
            'MediaProjectionForegroundService"',
          ),
        );
      },
      skip: merged.existsSync() ? null : 'run flutter build apk --debug first',
    );

    test(
      'asks for no camera, microphone or location either',
      () async {
        final xml = await merged.readAsString();

        // flutter_webrtc merges BLUETOOTH (maxSdkVersion 30) and
        // MODIFY_AUDIO_SETTINGS in on its own; neither records anything. What
        // must never appear is a permission that could.
        for (final permission in const [
          'android.permission.CAMERA',
          'android.permission.RECORD_AUDIO',
          'android.permission.ACCESS_FINE_LOCATION',
          'android.permission.ACCESS_COARSE_LOCATION',
        ]) {
          expect(xml, isNot(contains(permission)));
        }
      },
      skip: merged.existsSync() ? null : 'run flutter build apk --debug first',
    );
  });

  group('what the manifest must not ask for', () {
    test('no camera, no microphone, no location', () {
      for (final permission in const [
        'android.permission.CAMERA',
        'android.permission.RECORD_AUDIO',
        'android.permission.ACCESS_FINE_LOCATION',
        'android.permission.ACCESS_COARSE_LOCATION',
      ]) {
        expect(
          manifest,
          isNot(contains(permission)),
          reason: '$permission is not needed to share a screen',
        );
      }
    });

    test('no foreground-service type but mediaProjection', () {
      final types = RegExp(
        r'android:foregroundServiceType="([^"]*)"',
      ).allMatches(manifest).map((match) => match.group(1));

      expect(types, ['mediaProjection']);
    });
  });

  group('the capture this application asks Android for', () {
    late String source;

    setUpAll(() async {
      source = await File(
        'lib/features/screen_capture/data/flutter_webrtc_screen_media.dart',
      ).readAsString();
    });

    test('is video only', () {
      // The one place `getDisplayMedia` is called. Asserted on the source
      // because the constraints reach Android through a plugin's own method
      // channel, and a host test would be asserting Windows behaviour: the
      // plugin rewrites `video: true` on desktop and leaves it alone on
      // Android.
      expect(source, contains("'video': true"));
      expect(source, contains("'audio': false"));
      expect(source, isNot(contains("'audio': true")));
    });

    test('never opens a camera or a microphone', () {
      expect(source, isNot(contains('getUserMedia')));
      expect(source, isNot(contains('openCamera')));
    });

    test('asks for the whole display rather than a single app', () {
      // fullScreenOnly removes the "share one app" option from Android 14's
      // dialog. A technician walking someone through their tablet needs the
      // device, and a single-app share goes black the moment the user leaves
      // it — which reads as a broken session rather than as a choice.
      expect(source, contains('fullScreenOnly: true'));
    });
  });

  group('architecture', () {
    test('flutter_webrtc is imported by exactly two files', () async {
      // The peer connection adapter and the screen capture adapter. Everything
      // else speaks in this project's own types, which is what lets the
      // negotiation and the capture policy be tested without a native library
      // no unit test can start.
      final offenders = <String>[];

      await for (final entity in Directory('lib').list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final code = await entity.readAsString();
        if (code.contains('package:flutter_webrtc/')) {
          offenders.add(entity.path.replaceAll(r'\', '/'));
        }
      }

      expect(offenders..sort(), [
        'lib/features/screen_capture/data/flutter_webrtc_screen_media.dart',
        'lib/features/webrtc/data/flutter_webrtc_peer_connection_factory.dart',
      ]);
    });

    test('no domain or presentation code names a platform channel', () async {
      final offenders = <String>[];

      await for (final entity in Directory('lib').list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path.replaceAll(r'\', '/');
        if (!path.contains('/domain/') && !path.contains('/presentation/')) {
          continue;
        }
        // Comments are stripped first: a port's whole job is to say which
        // platform type it exists to keep out, and it can only say that by
        // naming it.
        final code = (await entity.readAsLines())
            .where((line) => !line.trimLeft().startsWith('//'))
            .join('\n');
        // The platform *types*, not the platform's vocabulary. A port called
        // `MediaProjectionForegroundService` is naming what it keeps out,
        // which is the opposite of leaking it; a port holding a
        // `MediaStreamTrack` would be the leak.
        const banned = [
          'MethodChannel',
          'MediaStreamTrack',
          'MediaProjectionManager',
          'getDisplayMedia',
          'package:flutter_webrtc/',
        ];
        if (banned.any(code.contains)) offenders.add(path);
      }

      expect(offenders, isEmpty);
    });
  });
}
