/// Holds the temporary Device JWT for the lifetime of the process.
///
/// The Device JWT is a *session* artifact, not a credential: it expires (24h by
/// default) and is re-obtained through `POST /device-auth/login` using the
/// permanent `deviceId` + `deviceSecret`. It is therefore deliberately not
/// persisted anywhere on disk.
abstract interface class DeviceTokenStore {
  /// Current Device JWT, or `null` when the device has no active session.
  String? get token;

  bool get hasToken;

  /// Incremented by every [clear] — every time authorisation is withdrawn.
  ///
  /// A login reads it before going to the network and installs its token only
  /// if it has not changed by the time the answer arrives (see
  /// `DeviceAuthRepositoryImpl.login`). Without it, a login still on the wire
  /// when authorisation was withdrawn — a confirmed refusal, a stop, a new
  /// attempt — would put a Device JWT back into a process that is no longer
  /// authorised.
  int get epoch;

  void save(String token);

  void clear();
}

/// In-memory implementation. Losing it on process death is intentional: the
/// session is restored from the permanent credential, never from a cached JWT.
class InMemoryDeviceTokenStore implements DeviceTokenStore {
  String? _token;
  int _epoch = 0;

  @override
  String? get token => _token;

  @override
  int get epoch => _epoch;

  @override
  bool get hasToken => _token != null;

  @override
  void save(String token) => _token = token;

  @override
  void clear() {
    _token = null;
    _epoch++;
  }
}
