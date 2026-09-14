/// The stable `error` values a signaling ACK may carry, per `REALTIME.md`.
///
/// The contract is explicit that these codes — not the human-readable strings
/// that may accompany them — are what a client branches on, so the wire values
/// live in exactly one place: the data-layer parser that reads them. Nothing
/// above the data layer ever compares an error string.
enum SignalingErrorCode {
  /// The payload does not satisfy the backend DTO: a missing or mistyped
  /// field, a size limit exceeded, or an unknown property included.
  ///
  /// Always a contract or programming error on this side. Retrying an
  /// identical payload can only produce an identical answer.
  invalidPayload,

  /// The socket has not joined that remote session, or is joined to another
  /// one. Only answered by `webrtc:*`, never by `remote-session:join`.
  ///
  /// The fix is to go back through `remote-session:join`; it is never to
  /// resend the message that was refused.
  notJoined,

  /// The session does not exist, is `CLOSED`, or belongs to another device.
  /// The three are indistinguishable on purpose.
  ///
  /// It says nothing about the `deviceSecret`: the socket's own handshake was
  /// already validated, so this is an ownership answer about one session, not
  /// a revoked credential.
  unauthorized,

  /// The destination namespace is not registered in the server yet. A
  /// transient server-side condition, not a client error.
  unavailable,

  /// A code this build has never heard of.
  ///
  /// Treated as "the attempt failed and nothing is known about why", which is
  /// the only safe reading: acting on a code whose meaning is unknown would be
  /// guessing, and guessing here means either a loop or a silent stall.
  unknown,
}
