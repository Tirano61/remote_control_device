import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_capture_result.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_video_track.dart';
import 'package:remote_control_device/features/screen_capture/domain/screen_capture_client.dart';
import 'package:remote_control_device/features/screen_capture/domain/screen_capture_platform.dart';

/// Everything that is a *decision* about screen capture, and nothing that is a
/// platform call.
///
/// The decisions are three, and each of them is a way this goes wrong when it
/// is not taken deliberately:
///
/// ```text
/// order      consent -> foreground service -> capture. Android 14 refuses
///            every other arrangement, natively.
///
/// reuse      one capture per RemoteSession, reused across peer connections,
///            never carried into the next RemoteSession.
///
/// cleanup    anything a failed start managed to switch on is switched back
///            off before the failure is reported.
/// ```
///
/// It touches no `flutter_webrtc` type and no `MethodChannel`, which is what
/// makes all three testable: the adapters behind the three ports are the only
/// part that needs a tablet.
class MediaProjectionScreenCaptureClient implements ScreenCaptureClient {
  MediaProjectionScreenCaptureClient({
    required ScreenCaptureConsent consent,
    required MediaProjectionForegroundService foregroundService,
    required ScreenMediaSource mediaSource,
  }) : _consent = consent,
       _foregroundService = foregroundService,
       _mediaSource = mediaSource;

  static const String _loggerName = 'screen';

  final ScreenCaptureConsent _consent;
  final MediaProjectionForegroundService _foregroundService;
  final ScreenMediaSource _mediaSource;

  ScreenMediaCapture? _capture;
  ScreenVideoTrack? _videoTrack;
  String? _remoteSessionId;

  /// Whether the foreground service was asked to start and not yet asked to
  /// stop. Set *before* the start is awaited, so that a start which threw
  /// half-way still gets a stop.
  bool _foregroundServiceRunning = false;

  /// The start in flight, and the session it is for. A second offer arriving
  /// while the user is still looking at the Android dialog must not put a
  /// second dialog on top of it.
  Future<ScreenCaptureResult>? _starting;
  String? _startingRemoteSessionId;

  @override
  bool get isActive => _videoTrack != null;

  @override
  String? get remoteSessionId => _remoteSessionId;

  @override
  Future<ScreenCaptureResult> requestAndStart(String remoteSessionId) {
    // A running capture for this very session is handed back as it is. This is
    // the whole point of the client holding state: a new peer connection
    // within one assistance session gets the track it already has, and the
    // user is not asked to authorise their screen twice for one technician.
    final track = _videoTrack;
    if (track != null && _remoteSessionId == remoteSessionId) {
      _log('capture reused for $remoteSessionId');
      return Future<ScreenCaptureResult>.value(ScreenCaptureStarted(track));
    }

    final starting = _starting;
    if (starting != null && _startingRemoteSessionId == remoteSessionId) {
      // Already asking for exactly this. Both callers get the one answer.
      return starting;
    }

    final pending = _start(remoteSessionId);
    _starting = pending;
    _startingRemoteSessionId = remoteSessionId;
    return pending.whenComplete(() {
      if (identical(_starting, pending)) {
        _starting = null;
        _startingRemoteSessionId = null;
      }
    });
  }

  Future<ScreenCaptureResult> _start(String remoteSessionId) async {
    // A capture belonging to another assistance session is never reused and
    // never left behind. Android grants a projection token for one capture;
    // carrying one across sessions is exactly what the platform stopped
    // allowing, and what the user did not agree to.
    if (_capture != null || _foregroundServiceRunning) await stop();

    _log('capture permission requested');
    bool granted;
    try {
      granted = await _consent.request();
    } catch (_) {
      // Nothing about the platform failure is printed: an Android exception
      // message here can carry the capture intent.
      _log('capture permission could not be requested');
      return const ScreenCaptureUnavailable(
        ScreenCaptureFailure.consentUnavailable,
      );
    }
    if (!granted) {
      _log('capture permission denied');
      return const ScreenCaptureDenied();
    }
    _log('capture permission granted');

    // Only now. The service is typed `mediaProjection`, and Android 14 refuses
    // to start one for an application that has not been granted a projection.
    _foregroundServiceRunning = true;
    try {
      await _foregroundService.start();
    } catch (_) {
      await _stopForegroundService();
      _log('foreground service could not be started');
      return const ScreenCaptureUnavailable(
        ScreenCaptureFailure.foregroundServiceRefused,
      );
    }
    _log('foreground service started');

    // And only now. The other way round -- capture first, service after -- is
    // the arrangement Android 14 throws a SecurityException for.
    ScreenMediaCapture capture;
    try {
      capture = await _mediaSource.open();
    } catch (_) {
      await _stopForegroundService();
      _log('capture could not be started');
      return const ScreenCaptureUnavailable(
        ScreenCaptureFailure.captureRefused,
      );
    }

    final videoTracks = capture.videoTracks;
    if (videoTracks.length != 1) {
      // A screen share is one video track. Anything else is a capture this
      // side cannot account for, and nothing unaccounted for is transmitted.
      _log('capture produced ${videoTracks.length} video tracks');
      await _dispose(capture);
      await _stopForegroundService();
      return const ScreenCaptureUnavailable(
        ScreenCaptureFailure.unexpectedTracks,
      );
    }

    _capture = capture;
    _videoTrack = videoTracks.single;
    _remoteSessionId = remoteSessionId;
    capture.onEnded = _onEndedByPlatform;

    _log('capture started');
    return ScreenCaptureStarted(videoTracks.single);
  }

  @override
  Future<void> stop() async {
    final capture = _capture;
    _capture = null;
    _videoTrack = null;
    _remoteSessionId = null;

    if (capture != null) {
      // Detached first, so this teardown cannot come back as "the platform
      // ended the capture" for a capture nobody holds any more.
      capture.onEnded = null;
      await _dispose(capture);
      _log('capture stopped');
    }
    await _stopForegroundService();
  }

  /// Android ended the capture on its own -- the user pressed *Stop sharing*
  /// in the system controls, or the projection was revoked.
  ///
  /// Everything this side holds is released and the notification comes down.
  /// Nothing else happens: the remote session stays open, the control channel
  /// stays open, and no renegotiation is attempted. Deciding what to offer the
  /// user after this is a question about product behaviour, and it is not
  /// answered in this build.
  void _onEndedByPlatform() {
    if (_capture == null) return;
    _log('capture stopped by the platform');
    unawaited(stop());
  }

  Future<void> _stopForegroundService() async {
    if (!_foregroundServiceRunning) return;
    _foregroundServiceRunning = false;
    try {
      await _foregroundService.stop();
    } catch (_) {
      // A service that is already gone is the outcome asked for, and a
      // teardown path has nothing left to do about anything else.
    }
  }

  Future<void> _dispose(ScreenMediaCapture capture) async {
    try {
      await capture.dispose();
    } catch (_) {
      // Same: releasing must never throw. Every failure path calls it.
    }
  }

  /// Never a frame, never a projection token, never a platform message. A
  /// remote session id is an operational identifier and is safe.
  static void _log(String message) {
    if (kDebugMode) developer.log(message, name: _loggerName);
  }
}
