import 'package:remote_control_device/features/screen_capture/domain/entities/screen_video_track.dart';

/// The three platform facilities a screen capture is made of.
///
/// They are separate ports rather than one, because the order they are used in
/// *is* the Android 14 contract and an order can only be observed when the
/// steps are distinguishable:
///
/// ```text
/// ScreenCaptureConsent              the MediaProjection dialog
///          |  the user accepts
///          v
/// MediaProjectionForegroundService  a service typed mediaProjection
///          |  it is running
///          v
/// ScreenMediaSource                 getDisplayMedia
/// ```
///
/// Getting that order wrong is not a style question. Starting the foreground
/// service first throws on Android 14, and starting the capture first throws
/// too — and both throw natively, where a Dart `catch` is not always enough to
/// keep the process alive. The policy that enforces the order is ordinary Dart
/// in `MediaProjectionScreenCaptureClient` and is tested against fakes of
/// these three; the adapters behind them are as thin as they can be made,
/// because they are the part no unit test can reach.

/// Asks the user for the screen.
abstract interface class ScreenCaptureConsent {
  /// Shows Android's capture dialog and answers what the user chose.
  ///
  /// `false` is a refusal and is not an error. Throwing means the dialog could
  /// not be shown at all.
  Future<bool> request();
}

/// The foreground service that keeps the capture legal and visible.
///
/// Android 14 requires a running service declared `foregroundServiceType=
/// "mediaProjection"` before a capture may start, and the persistent
/// notification it carries is how the user is told, at every moment and
/// without opening the app, that their screen is being shared.
abstract interface class MediaProjectionForegroundService {
  /// Starts it. Called only after the user has consented — the platform
  /// refuses it otherwise, and rightly so.
  Future<void> start();

  /// Stops it and removes the notification. Idempotent.
  Future<void> stop();
}

/// Opens the capture itself.
abstract interface class ScreenMediaSource {
  /// Starts a **video-only** screen capture.
  ///
  /// No audio is requested, here or anywhere else in this application: remote
  /// technical support needs to see the screen, and a microphone is not
  /// something a support session should be able to switch on. The manifest
  /// does not carry `RECORD_AUDIO` either, so there is nothing to ask with.
  Future<ScreenMediaCapture> open();
}

/// A running capture and the tracks it produced.
abstract interface class ScreenMediaCapture {
  /// The video tracks the capture yielded. A screen share is exactly one; the
  /// client refuses anything else rather than guessing which to send.
  List<ScreenVideoTrack> get videoTracks;

  /// Called when the capture ends without this application asking — the user
  /// pressing *Stop sharing* in Android's own controls, most of all.
  ///
  /// Set to `null` before tearing a capture down, so that stopping it does not
  /// come back as a notification about a capture nobody holds any more.
  set onEnded(void Function()? listener);

  /// Stops every track and releases the stream. Idempotent, and never throws:
  /// it is called from teardown paths that have nothing left to do about a
  /// failure.
  Future<void> dispose();
}
