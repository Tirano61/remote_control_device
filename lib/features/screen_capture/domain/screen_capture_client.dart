import 'package:remote_control_device/features/screen_capture/domain/entities/screen_capture_result.dart';

/// The boundary Android's `MediaProjection` lives behind.
///
/// Separate from `WebRtcPeerClient` on purpose, because the two have different
/// lifetimes and confusing them is how a screen ends up being captured for
/// nobody:
///
/// ```text
/// PeerConnection   one negotiation. Replaced whenever the technician's
///                  browser offers again; several may come and go within a
///                  single assistance session.
///
/// MediaProjection  one RemoteSession. Android treats each capture as a
///                  session of its own and the user consents to each one, so
///                  it must survive a peer connection being rebuilt and must
///                  not survive the assistance ending.
/// ```
///
/// That is the whole reason [requestAndStart] takes a remote session id. It is
/// not used to authorise anything — authorisation is the backend's, and by the
/// time this is called the user has already accepted the technician — it is
/// used to answer one question: *is this the same capture, or a new one?*
///
/// Nothing above this port names a `MediaStream`, a `MediaStreamTrack`,
/// `Helper`, `navigator.mediaDevices`, a `MethodChannel` or `MediaProjection`.
abstract interface class ScreenCaptureClient {
  /// Whether a capture is running right now.
  bool get isActive;

  /// The remote session the running capture belongs to, or `null`.
  String? get remoteSessionId;

  /// Starts sharing the screen for [remoteSessionId], asking the user first.
  ///
  /// The order is Android's and is not negotiable:
  ///
  /// ```text
  /// consent  ->  mediaProjection foreground service  ->  capture
  /// ```
  ///
  /// Called again for the *same* [remoteSessionId] while a capture is running,
  /// it returns the running one and the user is not asked a second time — a
  /// new peer connection within one assistance session reuses the track it
  /// already has. Called for a *different* remote session, the running capture
  /// is stopped first and consent is asked for again, because a
  /// `MediaProjection` token is granted for one capture and reusing it across
  /// assistance sessions is precisely what Android 14 stopped allowing.
  ///
  /// Never throws. Every failure is one of the [ScreenCaptureResult] values,
  /// because the caller is answering a WebRTC offer and must be able to finish
  /// answering it without the screen.
  Future<ScreenCaptureResult> requestAndStart(String remoteSessionId);

  /// Whether the running capture's frames may reach the technician.
  ///
  /// Capturing and transmitting are two things. A capture starts with nothing
  /// transmitted — the Android side keeps every frame back, before the
  /// encoder — and transmits only after this is called with `true`; `false`
  /// keeps every frame back again while MediaProjection, its consent and its
  /// notification stay, so a session that recovers needs no second dialog.
  ///
  /// Calls take effect in the order they are made. With no capture running
  /// there is nothing to transmit, and nothing happens.
  ///
  /// Never throws. Returns `false` only when the platform could not apply the
  /// change: the capture has then been stopped — a capture this side cannot
  /// hold back is not left running — and the caller treats it as a failed
  /// screen. `true` otherwise.
  Future<bool> setTransmitting(bool transmitting);

  /// Stops the capture, releases the track and the stream, and takes the
  /// foreground notification down.
  ///
  /// Idempotent. Several paths lead here — the session closed by either end, a
  /// revoked credential, the application shutting down — and none of them can
  /// know whether it is first.
  Future<void> stop();

  /// The remote session of every capture that Android ended by itself —
  /// MediaProjection's `onStop`: the user pressed *Stop sharing* in the system
  /// controls, or another projection took over.
  ///
  /// By the time an id arrives here the capture has already been released and
  /// the notification taken down. A capture this application stopped itself
  /// never appears. Nothing restarts the capture in response: that would take
  /// a new Android dialog, in a new assistance.
  Stream<String> get endedByPlatform;
}
