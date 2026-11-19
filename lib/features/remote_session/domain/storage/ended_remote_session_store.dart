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
/// What is stored is the `remoteSessionId` and whether this tablet still owes
/// the backend a close for it, nothing else. The id is an operational
/// identifier, not a credential: it grants nothing, it is safe to log, and the
/// backend still checks ownership on every call made with it.
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
  Future<EndedRemoteSessionMarker?> read();

  /// Records [marker] as ended here, replacing any previous one.
  ///
  /// Throws [EndedRemoteSessionStoreException] if the store cannot be written.
  Future<void> write(EndedRemoteSessionMarker marker);

  /// Forgets the marker: the backend confirmed the session is no longer live.
  ///
  /// Throws [EndedRemoteSessionStoreException] if the store cannot be written.
  Future<void> clear();
}

/// One session ended on this tablet and not yet confirmed closed.
///
/// [closeOwed] says how the backend is meant to learn about it:
///
/// ```text
/// true    the user pressed FINALIZAR: the tablet sends
///         POST /device/remote-sessions/:id/close, and sends it again on the
///         next read that still finds the session live (endedBy DEVICE)
/// false   the tablet stopped it by itself because it could not confirm it
///         with the backend in time. Nothing is sent: the device no longer
///         takes part in the session, so the backend closes it on its own
///         (endedBy SYSTEM). A close sent here would be recorded as if the
///         user had pressed FINALIZAR.
/// ```
///
/// Either way the session is refused as live from the moment it was ended.
class EndedRemoteSessionMarker {
  const EndedRemoteSessionMarker(this.remoteSessionId, {this.closeOwed = true});

  final String remoteSessionId;
  final bool closeOwed;

  @override
  bool operator ==(Object other) =>
      other is EndedRemoteSessionMarker &&
      other.remoteSessionId == remoteSessionId &&
      other.closeOwed == closeOwed;

  @override
  int get hashCode => Object.hash(remoteSessionId, closeOwed);

  @override
  String toString() =>
      'EndedRemoteSessionMarker($remoteSessionId, closeOwed: $closeOwed)';
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
