import 'dart:async';

import 'package:remote_control_device/features/screen_capture/domain/entities/screen_capture_result.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_video_track.dart';
import 'package:remote_control_device/features/screen_capture/domain/screen_capture_client.dart';
import 'package:remote_control_device/features/screen_capture/domain/screen_capture_platform.dart';

/// Stand-ins for Android's `MediaProjection`.
///
/// A unit test cannot show a consent dialog, cannot answer one, cannot start a
/// foreground service and cannot capture a screen — which is exactly why the
/// three platform facilities are separate ports. Everything that decides
/// something about screen capture is ordinary Dart and is tested against
/// these; what is left behind them is two `flutter_webrtc` calls and a
/// `MethodChannel`, verified where they can only be verified.

/// A screen video track that exists only as a name.
class FakeScreenVideoTrack implements ScreenVideoTrack {
  const FakeScreenVideoTrack(this.id);

  @override
  final String id;

  @override
  String toString() => 'FakeScreenVideoTrack($id)';
}

const ScreenVideoTrack testScreenVideoTrack = FakeScreenVideoTrack(
  'screen-track-1',
);

/// The three platform ports, recording into one shared list.
///
/// One list and not three, because the thing under test is an *order*: Android
/// 14 refuses a foreground service started before consent and refuses a
/// capture started before the service, and an order can only be asserted where
/// the steps are written down together.
class FakeScreenCapturePlatform {
  final List<String> calls = [];

  late final FakeScreenCaptureConsent consent = FakeScreenCaptureConsent(this);
  late final FakeMediaProjectionForegroundService foregroundService =
      FakeMediaProjectionForegroundService(this);
  late final FakeScreenMediaSource mediaSource = FakeScreenMediaSource(this);

  /// What the consent dialog answers.
  bool granted = true;

  /// When true, showing the dialog throws instead of answering.
  bool consentThrows = false;

  /// When true, starting the foreground service throws.
  bool foregroundServiceStartThrows = false;

  /// When set, a started foreground service does not report READY until the
  /// test completes this — Android between `startForegroundService` and the
  /// service's own `startForeground`, which is exactly the window a capture
  /// must not be opened in. Never completing it is a service that never
  /// answers. A stop while it is pending fails it, as the Android side does.
  Completer<void>? foregroundServiceReadyGate;

  /// When true, opening the capture throws.
  bool captureThrows = false;

  /// When true, changing a capture's transmission throws.
  bool transmissionThrows = false;

  /// The tracks the next capture yields. A real screen share is exactly one.
  List<ScreenVideoTrack> nextVideoTracks = const [testScreenVideoTrack];

  /// When set, the consent dialog does not answer until the test completes it
  /// — the only way to observe what happens while a user is looking at it.
  Completer<void>? consentGate;

  /// Every capture that was opened, in order.
  final List<FakeScreenMediaCapture> captures = [];

  FakeScreenMediaCapture get lastCapture => captures.last;

  bool get foregroundServiceRunning =>
      calls.where((call) => call == 'foregroundService.start').length >
      calls.where((call) => call == 'foregroundService.stop').length;
}

class FakeScreenCaptureConsent implements ScreenCaptureConsent {
  FakeScreenCaptureConsent(this._platform);

  final FakeScreenCapturePlatform _platform;

  @override
  Future<bool> request() async {
    _platform.calls.add('consent.request');
    await _platform.consentGate?.future;
    if (_platform.consentThrows) throw StateError('no activity');
    return _platform.granted;
  }
}

class FakeMediaProjectionForegroundService
    implements MediaProjectionForegroundService {
  FakeMediaProjectionForegroundService(this._platform);

  final FakeScreenCapturePlatform _platform;

  @override
  Future<void> start() async {
    _platform.calls.add('foregroundService.start');
    if (_platform.foregroundServiceStartThrows) {
      throw StateError('foreground service refused');
    }
    await _platform.foregroundServiceReadyGate?.future;
    _platform.calls.add('foregroundService.ready');
  }

  @override
  Future<void> stop() async {
    _platform.calls.add('foregroundService.stop');
    final gate = _platform.foregroundServiceReadyGate;
    if (gate != null && !gate.isCompleted) {
      gate.completeError(StateError('STOPPED'));
    }
  }
}

class FakeScreenMediaSource implements ScreenMediaSource {
  FakeScreenMediaSource(this._platform);

  final FakeScreenCapturePlatform _platform;

  @override
  Future<ScreenMediaCapture> open() async {
    _platform.calls.add('mediaSource.open');
    if (_platform.captureThrows) throw StateError('capture failed');

    final capture = FakeScreenMediaCapture(
      _platform,
      _platform.nextVideoTracks,
    );
    _platform.captures.add(capture);
    return capture;
  }
}

class FakeScreenMediaCapture implements ScreenMediaCapture {
  FakeScreenMediaCapture(this._platform, this.videoTracks);

  final FakeScreenCapturePlatform _platform;

  @override
  final List<ScreenVideoTrack> videoTracks;

  void Function()? _onEnded;
  int disposeCount = 0;

  /// What the Android side's gate is, as the calls left it. Starts closed.
  bool transmitting = false;

  /// Every transmission change asked of this capture, in order.
  final List<bool> transmissionCalls = [];

  bool get isDisposed => disposeCount > 0;
  bool get isListened => _onEnded != null;

  @override
  set onEnded(void Function()? listener) => _onEnded = listener;

  @override
  Future<void> dispose() async {
    disposeCount++;
    _platform.calls.add('capture.dispose');
  }

  @override
  Future<void> setTransmitting(bool transmitting) async {
    _platform.calls.add('capture.transmit:$transmitting');
    transmissionCalls.add(transmitting);
    if (_platform.transmissionThrows) throw StateError('gate unavailable');
    if (isDisposed) return;
    this.transmitting = transmitting;
  }

  /// Android ended the capture on its own — the user pressing *Stop sharing*
  /// in the system controls.
  void endFromPlatform() => _onEnded?.call();
}

/// The client itself, for tests about what the *negotiation* does with it.
class FakeScreenCaptureClient implements ScreenCaptureClient {
  /// The sessions [requestAndStart] was called for, in order. A second entry
  /// for one session is a second Android dialog the user should not have seen.
  final List<String> requests = [];

  /// The requests that would have shown Android's dialog: no capture of that
  /// session was running. A request for the session already captured is
  /// handed the running capture back, as the real client does, and is not in
  /// here.
  final List<String> dialogs = [];

  int stopCount = 0;

  /// What the next start produces. Replaced wholesale by a test that wants a
  /// refusal or a failure.
  ScreenCaptureResult result = const ScreenCaptureStarted(testScreenVideoTrack);

  /// When set, starting does not answer until the test completes it — a user
  /// taking their time over Android's dialog.
  Completer<void>? startGate;

  bool _active = false;
  String? _remoteSessionId;

  /// Whether frames of the running capture reach the technician right now. A
  /// capture starts with them kept back, as the real one does natively.
  bool transmitting = false;

  /// Every transmission change that reached a running capture, in order, as
  /// `(remote session, transmitting)`. Repeats are not recorded: the real
  /// client sends nothing for them.
  final List<(String, bool)> transmissions = [];

  /// When true, the next change fails: the capture is stopped and `false`
  /// returned, as the real client does when the platform refuses it.
  bool transmissionFails = false;

  /// Frames the technician would receive: one per [screenChanged] made while
  /// [transmitting]. What a frame counter on the receiving side would count.
  int framesSent = 0;

  /// Frames the capture produced while held back.
  int framesWithheld = 0;

  /// The screen changed. Counted as sent only while transmitting, and only
  /// while a capture runs at all.
  void screenChanged() {
    if (!_active) return;
    if (transmitting) {
      framesSent++;
    } else {
      framesWithheld++;
    }
  }

  @override
  bool get isActive => _active;

  @override
  String? get remoteSessionId => _remoteSessionId;

  @override
  Future<ScreenCaptureResult> requestAndStart(String remoteSessionId) async {
    requests.add(remoteSessionId);
    if (!_active || _remoteSessionId != remoteSessionId) {
      dialogs.add(remoteSessionId);
    }
    await startGate?.future;

    final outcome = result;
    if (outcome is ScreenCaptureStarted) {
      // A running capture for the same session is handed back as it is;
      // anything else is a new one, which starts held back.
      if (!_active || _remoteSessionId != remoteSessionId) transmitting = false;
      _active = true;
      _remoteSessionId = remoteSessionId;
    }
    return outcome;
  }

  @override
  Future<bool> setTransmitting(bool transmitting) async {
    final remoteSessionId = _remoteSessionId;
    if (!_active || remoteSessionId == null) return true;
    if (this.transmitting == transmitting) return true;
    if (transmissionFails) {
      transmissionFails = false;
      await stop();
      return false;
    }
    this.transmitting = transmitting;
    transmissions.add((remoteSessionId, transmitting));
    return true;
  }

  /// Called at the moment [stop] is, before anything is released. Lets a test
  /// observe what had already been taken down by then.
  void Function()? onStop;

  @override
  Future<void> stop() async {
    onStop?.call();
    stopCount++;
    _active = false;
    _remoteSessionId = null;
    transmitting = false;
  }

  final StreamController<String> _endedByPlatform =
      StreamController<String>.broadcast(sync: true);

  @override
  Stream<String> get endedByPlatform => _endedByPlatform.stream;

  /// Android's MediaProjection `onStop`, as the real client reports it: the
  /// capture is released first, then its session is announced.
  void endFromPlatform() {
    final remoteSessionId = _remoteSessionId;
    if (remoteSessionId == null) return;
    _active = false;
    _remoteSessionId = null;
    transmitting = false;
    stopCount++;
    _endedByPlatform.add(remoteSessionId);
  }
}
