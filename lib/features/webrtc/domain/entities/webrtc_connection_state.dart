/// The peer connection's own state, as WebRTC defines it.
///
/// A copy of `RTCPeerConnectionState` in this project's vocabulary, so that
/// nothing above the data layer names a `flutter_webrtc` type. The six values
/// are the standard ones, and the mapping is one-to-one — there is no room for
/// interpretation here, and interpretation is exactly what a peer connection
/// state must not be subjected to.
enum WebRtcConnectionState {
  /// `new`. The connection exists and nothing has been attempted yet. Spelled
  /// [initial] because `new` is a Dart keyword.
  initial,

  /// One or more transports are being established.
  connecting,

  /// Every transport is connected. This is half of what this stage calls
  /// success; the other half is the `control` channel being open.
  connected,

  /// A transport dropped. Potentially transient: WebRTC may recover on its own,
  /// so nothing is torn down here and no timer is started.
  disconnected,

  /// A transport failed terminally. The negotiation is over; a new one needs a
  /// new offer.
  failed,

  /// The connection was closed, by either end.
  closed,
}
