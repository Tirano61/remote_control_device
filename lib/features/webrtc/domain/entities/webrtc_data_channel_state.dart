/// A data channel's own state, as WebRTC defines it.
///
/// Kept apart from [WebRtcConnectionState] because they are genuinely separate
/// facts and either can move without the other: a peer connection can be
/// `connected` while the `control` channel is still `connecting`, and a channel
/// can close while the connection stays up.
enum WebRtcDataChannelState {
  /// The channel exists and its transport is still being set up.
  connecting,

  /// Usable. Together with a connected peer connection, this is what this stage
  /// calls a working remote connection — nothing is sent over it yet.
  open,

  /// Closing was requested and has not finished.
  closing,

  /// Closed. A channel never leaves this state; a new one is a new channel.
  closed,
}
