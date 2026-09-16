/// The statuses `ENDPOINTS.md` documents for a `RemoteSession`.
///
/// Typed on purpose, exactly like the support statuses: the wire values exist
/// in a single place — the data model that reads them — so no screen and no
/// bloc ever compares a status string.
enum RemoteSessionStatus {
  /// The session exists and both ends may start connecting. Every session the
  /// backend creates today starts — and stays — here.
  connecting,

  /// The remote connection is established. Written by one backend path only —
  /// `POST /remote-sessions/:id/activate`, which the technician calls once
  /// WebRTC is connected and the control channel is open — and never by this
  /// client, which has no such call and only ever reads the result.
  active,

  /// The session ended. Terminal, and never returned by
  /// `GET /device/remote-sessions/current` — only by the close response.
  closed,

  /// A value this build of the client does not know.
  ///
  /// The contract asks clients to treat future values defensively. The
  /// defensive answer is to admit ignorance: an unknown status is never
  /// rendered as if it were one of the known ones, and above all is never
  /// treated as live — a session this client cannot interpret must not put a
  /// "remote assistance in progress" screen in front of the user.
  unknown;

  /// Whether the backend considers the session live. Only one live session
  /// exists per device at a time.
  bool get isLive => this == connecting || this == active;
}
