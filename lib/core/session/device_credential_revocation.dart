import 'dart:async';

/// Single channel through which any authenticated exchange can report that the
/// *permanent* credential — not merely the temporary Device JWT — is no longer
/// accepted by the backend.
///
/// It exists so that the two places able to discover the fact reach the same
/// consequence without either of them implementing it:
///
/// ```text
/// Socket.IO handshake refused ──> renew ──> 401 ─┐
///                                               ├──> report() ──> the session
/// authenticated REST call 401 ──> renew ──> 401 ─┘               wipes the
///                                                                credential and
///                                                                requires
///                                                                re-enrollment
/// ```
///
/// Nothing is carried on the wire: the fact itself is the whole message, and it
/// deliberately does not say which call discovered it.
class DeviceCredentialRevocation {
  final StreamController<void> _controller = StreamController<void>.broadcast();

  /// Fires once per discovery. Broadcast, so wiring up late is allowed — a
  /// report with no listener is simply dropped, and the next authenticated call
  /// would discover the same thing again.
  Stream<void> get revocations => _controller.stream;

  void report() {
    if (_controller.isClosed) return;
    _controller.add(null);
  }

  Future<void> dispose() async {
    if (!_controller.isClosed) await _controller.close();
  }
}
