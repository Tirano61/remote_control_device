/// Where screen sharing is, told separately from everything else.
///
/// It is its own axis on purpose. The success condition of the remote
/// connection is unchanged by this prompt:
///
/// ```text
/// PeerConnection connected  +  control DataChannel open  =  WebRTC usable
/// ```
///
/// and the screen is an extra capability layered on top. A user who declines
/// the Android capture dialog still has a working assistance session, the
/// backend still moves the remote session to `ACTIVE`, and the technician still
/// holds an open control channel. Folding screen capture into that condition
/// would turn a refused permission into a broken session.
enum ScreenCaptureStatus {
  /// Nothing is being captured and nothing is being asked for.
  idle,

  /// Android's capture consent dialog is up, or the capture is being started
  /// right after it.
  requesting,

  /// `MediaProjection` is running and its video track is on the peer
  /// connection.
  active,

  /// The user declined the Android dialog. Not an error: it is an answer, and
  /// the assistance carries on without the screen.
  denied,

  /// The capture could not be started or could not be attached — the
  /// foreground service was refused, `getDisplayMedia` failed, or the offer
  /// carried no video section to answer on.
  failed,
}
