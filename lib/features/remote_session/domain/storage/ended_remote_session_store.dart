/// Remembers, across restarts, the one remote session the user of this tablet
/// ended and the backend has not yet confirmed as closed.
///
/// It exists because ending an assistance is irreversible *here*, whatever the
/// backend has heard so far. When `FINALIZAR ASISTENCIA` cannot reach the
/// server, the backend still holds the session `ACTIVE`, and the very next
/// `GET /device/remote-sessions/current` — after a reconnection, or after the
/// application was killed and opened again — would hand it straight back. This
/// marker is what makes the tablet refuse it: a session named here is never
/// adopted as live again, only closed.
///
/// What is stored is the `remoteSessionId` and nothing else. It is an
/// operational identifier, not a credential: it grants nothing, it is safe to
/// log, and the backend still checks ownership on every call made with it.
///
/// The marker is cleared only by the backend: a close it confirmed, or a read
/// of `/current` showing that session is no longer live for this device. A
/// different session never clears it by being adopted, and never needs to —
/// a device holds at most one live session at a time.
abstract interface class EndedRemoteSessionStore {
  /// The session ended on this tablet and still awaiting the backend's
  /// confirmation, or `null`.
  ///
  /// Throws [EndedRemoteSessionStoreException] if the store cannot be read.
  Future<String?> read();

  /// Records [remoteSessionId] as ended here, replacing any previous one.
  ///
  /// Throws [EndedRemoteSessionStoreException] if the store cannot be written.
  Future<void> write(String remoteSessionId);

  /// Forgets the marker: the backend confirmed the session is no longer live.
  ///
  /// Throws [EndedRemoteSessionStoreException] if the store cannot be written.
  Future<void> clear();
}

/// The underlying store failed. Free of any package-specific type so the
/// domain stays independent of the implementation.
class EndedRemoteSessionStoreException implements Exception {
  const EndedRemoteSessionStoreException([this.debugDetail]);

  final String? debugDetail;

  @override
  String toString() =>
      'EndedRemoteSessionStoreException(${debugDetail ?? 'no detail'})';
}
