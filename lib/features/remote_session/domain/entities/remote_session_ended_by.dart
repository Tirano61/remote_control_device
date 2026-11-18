/// Who closed a remote session, as `remote-session:closed` reports it.
///
/// `RemoteSessionEndedBy` in the backend contract. Used only to tell the user
/// who ended the assistance: no decision in this client depends on it. Every
/// value — including one this build has never heard of — means the same thing
/// to the tablet: the session is over.
enum RemoteSessionEndedBy {
  technician,
  device,

  /// The backend closed it by itself (`SYSTEM`): a side stayed away longer
  /// than the grace period, or the session never became `ACTIVE`.
  system,

  /// Absent, or a value this build does not know.
  unknown;

  /// Maps the wire value. Never throws: an unknown value is [unknown].
  static RemoteSessionEndedBy fromWire(String? value) => switch (value) {
    'TECHNICIAN' => technician,
    'DEVICE' => device,
    'SYSTEM' => system,
    _ => unknown,
  };
}
