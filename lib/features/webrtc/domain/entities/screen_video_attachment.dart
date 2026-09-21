/// What happened when the screen's video track was put on the peer connection.
///
/// Three outcomes and no exception, because the caller is in the middle of
/// answering an offer: whichever of these comes back, an answer is still
/// created and the `control` channel still opens. The screen is an extra
/// capability, and losing it must never cost the assistance session.
enum ScreenVideoAttachment {
  /// The video transceiver the offer created is now `sendonly` and carries the
  /// screen track. This is the only outcome in which video is negotiated.
  attached,

  /// The applied offer has no video section.
  ///
  /// `remote_control_web` creates a `recvonly` video transceiver before it
  /// offers, so this means the two ends disagree about what is being
  /// negotiated — an older web build, most likely. Nothing is invented to
  /// paper over it: no transceiver is added, no SDP is rewritten, and the
  /// negotiation continues with the data channel alone.
  noVideoTransceiver,

  /// The transceiver was there and the attachment still failed.
  failed,
}
