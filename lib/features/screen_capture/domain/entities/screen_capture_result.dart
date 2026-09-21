import 'package:equatable/equatable.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_video_track.dart';

/// Why a capture could not be started, when the user did not refuse it.
///
/// Kept apart from [ScreenCaptureDenied] because the two are different facts
/// about different actors: one is the user's answer, the other is the device
/// failing to do what the user allowed. Only the name of the value is ever
/// logged — never a platform message, which on Android can quote an intent.
enum ScreenCaptureFailure {
  /// The consent dialog could not even be shown. On a build without an
  /// activity — or on a platform that has no `MediaProjection` at all — this
  /// is what asking produces.
  consentUnavailable,

  /// The `mediaProjection` foreground service refused to start. Android 14
  /// requires it to be running before a capture may begin, so there is no
  /// capture to be had without it.
  foregroundServiceRefused,

  /// `getDisplayMedia` failed after consent and after the service was up.
  captureRefused,

  /// The capture returned, but not with the single video track a screen share
  /// is. Nothing is sent from a stream this side cannot account for.
  unexpectedTracks,
}

/// What asking for the screen produced.
///
/// Three outcomes and no exceptions: every caller of
/// `ScreenCaptureClient.requestAndStart` is in the middle of answering a
/// WebRTC offer, and an offer that is not answered because a permission dialog
/// threw is a remote assistance session that never starts. The failure modes
/// are values here so that the negotiation can keep going through all of them.
sealed class ScreenCaptureResult extends Equatable {
  const ScreenCaptureResult();

  @override
  List<Object?> get props => const [];
}

/// `MediaProjection` is running and this is the track it produces.
///
/// The track is owned by the client that returned it, not by the caller.
/// Whoever receives it may attach it to a peer connection and nothing else —
/// stopping it is the client's job, because the client is the only thing that
/// knows whether another negotiation for the same remote session is about to
/// want it again.
final class ScreenCaptureStarted extends ScreenCaptureResult {
  const ScreenCaptureStarted(this.videoTrack);

  final ScreenVideoTrack videoTrack;

  @override
  List<Object?> get props => [videoTrack];
}

/// The user said no to Android's capture dialog.
///
/// An expected, ordinary answer. Remote support here is assisted by design:
/// the user authorises the technician, and authorising the technician is not
/// the same as handing over the screen.
final class ScreenCaptureDenied extends ScreenCaptureResult {
  const ScreenCaptureDenied();
}

/// The user allowed it, or was never asked, and it still did not start.
final class ScreenCaptureUnavailable extends ScreenCaptureResult {
  const ScreenCaptureUnavailable(this.reason);

  final ScreenCaptureFailure reason;

  @override
  List<Object?> get props => [reason];
}
