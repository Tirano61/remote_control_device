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

  void save(String token);

  void clear();
}

/// In-memory implementation. Losing it on process death is intentional: the
/// session is restored from the permanent credential, never from a cached JWT.
class InMemoryDeviceTokenStore implements DeviceTokenStore {
  String? _token;

  @override
  String? get token => _token;

  @override
  bool get hasToken => _token != null;

  @override
  void save(String token) => _token = token;

  @override
  void clear() => _token = null;
}
