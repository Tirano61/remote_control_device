import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_video_track.dart';
import 'package:remote_control_device/features/screen_capture/domain/screen_capture_platform.dart';

/// The part of screen capture that only a tablet can verify.
///
/// Two calls into `flutter_webrtc` and nothing else — no order, no reuse, no
/// cleanup, no retry. All of those are decisions and they live in
/// `MediaProjectionScreenCaptureClient`, where they can be tested; what is
/// left here is the translation that needs a real `MediaProjection` to run at
/// all.
///
/// What the installed plugin actually offers, checked against
/// `flutter_webrtc 1.6.2+hotfix.2` rather than remembered:
///
/// ```text
/// Helper.requestCapturePermission({bool fullScreenOnly = false})
///     -> MethodChannel("FlutterWebRTC.Method").requestCapturePermission
///     -> shows MediaProjectionManager.createScreenCaptureIntent()
///     -> stores the granted Intent in GetUserMediaImpl.mediaProjectionData
///     -> answers true / false
///
/// navigator.mediaDevices.getDisplayMedia(constraints)
///     -> reuses that stored Intent when it is there, and only shows the
///        dialog itself when it is not
/// ```
///
/// That second line is why this application does not manage a
/// `MediaProjectionManager` of its own: the plugin already holds the token and
/// already reuses it, and a second one would mean two consents for one share.
/// What the plugin does *not* do is run a foreground service — that is this
/// application's obligation under Android 14, and it is a separate port.

/// Android's capture consent dialog.
class FlutterWebRtcScreenCaptureConsent implements ScreenCaptureConsent {
  const FlutterWebRtcScreenCaptureConsent();

  /// `fullScreenOnly` asks Android 14+ for
  /// `MediaProjectionConfig.createConfigForDefaultDisplay()`, which removes
  /// the "share one app" option from the dialog.
  ///
  /// Deliberate for this product: a technician assisting someone on a tablet
  /// is walking them through the device, not through one application, and a
  /// single-app share would show a black screen the moment the user leaves
  /// it — which reads as a broken session rather than as a choice they made.
  /// On older Android versions the flag has no effect and the platform's own
  /// dialog is shown.
  @override
  Future<bool> request() =>
      rtc.Helper.requestCapturePermission(fullScreenOnly: true);
}

/// `getDisplayMedia`, video only.
class FlutterWebRtcScreenMediaSource implements ScreenMediaSource {
  const FlutterWebRtcScreenMediaSource();

  @override
  Future<ScreenMediaCapture> open() async {
    final stream = await rtc.navigator.mediaDevices.getDisplayMedia(
      // No width, no height, no frame rate. The Android capturer already
      // matches the display's real size and picks its own rate; pinning
      // numbers here before a capture has been seen working on the tablets
      // this runs on would be guessing at a trade-off nobody has measured.
      <String, dynamic>{'video': true, 'audio': false},
    );
    return FlutterWebRtcScreenMediaCapture(stream);
  }
}

/// A capture in progress, and the one place the real stream is held.
class FlutterWebRtcScreenMediaCapture implements ScreenMediaCapture {
  FlutterWebRtcScreenMediaCapture(this._stream)
    : _videoTracks = [
        for (final track in _stream.getVideoTracks())
          FlutterWebRtcScreenVideoTrack(track),
      ];

  final rtc.MediaStream _stream;
  final List<FlutterWebRtcScreenVideoTrack> _videoTracks;

  bool _disposed = false;

  @override
  List<ScreenVideoTrack> get videoTracks => _videoTracks;

  /// The plugin declares `MediaStreamTrack.onEnded` on every platform, so the
  /// listener is attached wherever it is offered.
  ///
  /// On Android it does not currently fire: `flutter_webrtc
  /// 1.6.2+hotfix.2` never raises an `ended` event from native code, and the
  /// `MediaProjection.Callback.onStop` it installs deliberately does nothing.
  /// So a user who stops the share from Android's own controls is *not*
  /// noticed by this build; what they see is the capture ending, the
  /// assistance carrying on, and the notification going away with the session.
  /// Attaching it anyway costs nothing and is correct the day the plugin
  /// starts raising it.
  @override
  set onEnded(void Function()? listener) {
    for (final track in _videoTracks) {
      track.track.onEnded = listener;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    for (final track in _videoTracks) {
      track.track.onEnded = null;
      try {
        // `trackDispose` on the Android side, which also removes the screen
        // capturer and stops MediaProjection.
        await track.track.stop();
      } catch (_) {
        // A track that is already gone natively is the outcome asked for.
      }
    }
    try {
      await _stream.dispose();
    } catch (_) {
      // Same. Releasing must never throw: every teardown path calls it.
    }
  }
}

/// The screen's video track, with the `flutter_webrtc` object still attached.
///
/// The one type that crosses from this adapter to the WebRTC one, and the
/// reason it is public: attaching a track to a transceiver has to happen
/// inside `flutter_webrtc`, so the peer connection adapter needs to get the
/// real object back out. It gets it by asking for this type and nothing else —
/// a [ScreenVideoTrack] from anywhere but here is refused rather than guessed
/// at.
class FlutterWebRtcScreenVideoTrack implements ScreenVideoTrack {
  const FlutterWebRtcScreenVideoTrack(this.track);

  final rtc.MediaStreamTrack track;

  /// libwebrtc types it as nullable; a track without an id cannot be looked up
  /// natively and is refused by the same check that refuses a foreign handle.
  @override
  String get id => track.id ?? '';
}
