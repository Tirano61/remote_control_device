/// The statuses `ENDPOINTS.md` documents for a `SupportRequest`.
///
/// Typed on purpose: the wire values appear in exactly one place — the data
/// model that reads them — so no screen or bloc ever compares a status string.
enum SupportRequestStatus {
  /// The tablet asked for assistance; no technician has taken it.
  waiting,

  /// A technician took it; the user has not answered yet.
  assigned,

  /// The user authorized that technician. Does **not** imply a session exists.
  accepted,

  /// The user refused the technician. Terminal.
  rejected,

  /// The user withdrew the request. Terminal.
  cancelled,

  /// A remote session existed and was closed. Terminal; only the backend
  /// writes it.
  completed,

  /// A value this build of the client does not know.
  ///
  /// The contract asks clients to treat future values defensively, and the
  /// defensive answer is to admit ignorance rather than to guess at a meaning:
  /// an unknown status is never rendered as if it were one of the known ones.
  unknown;

  /// Whether the backend considers the request live. Only one active request
  /// exists per device at a time.
  bool get isActive =>
      this == waiting || this == assigned || this == accepted;
}
