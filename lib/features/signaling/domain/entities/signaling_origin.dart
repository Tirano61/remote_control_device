/// Which end of a remote session sent a relayed `webrtc:*` message.
///
/// The backend adds it as `from` on the way out and never reads it from the
/// sender, so it is one of the few fields on a signaling payload that cannot be
/// forged by the peer. On a `/devices` socket every relayed message arrives
/// from [technician]; [device] exists because the contract documents one enum
/// for both namespaces.
enum SignalingOrigin {
  /// `DEVICE`.
  device,

  /// `TECHNICIAN`.
  technician,

  /// A value this build has never heard of. Carried rather than rejected: the
  /// message is authorised by the session it belongs to, not by who claims to
  /// have sent it, so a new participant kind must not void a valid SDP.
  unknown,
}
