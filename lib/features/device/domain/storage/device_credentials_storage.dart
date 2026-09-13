import 'package:remote_control_device/features/device/domain/entities/device_credentials.dart';

/// Port for the persistent, hardware-backed storage of the device credentials.
///
/// The domain and the presentation layer depend on this abstraction only; the
/// concrete secure-storage package lives behind it in the data layer.
abstract interface class DeviceCredentialsStorage {
  /// Returns the stored credentials, or `null` when the device is not enrolled.
  ///
  /// Throws [DeviceCredentialsStorageException] if the store cannot be read.
  Future<DeviceCredentials?> read();

  /// Persists the credentials, replacing any previous pair.
  ///
  /// Throws [DeviceCredentialsStorageException] if the store cannot be written.
  Future<void> save(DeviceCredentials credentials);

  /// Removes the credentials. Used when the backend revokes them.
  ///
  /// Throws [DeviceCredentialsStorageException] if the store cannot be written.
  Future<void> clear();
}

/// Raised when the underlying secure store fails. Deliberately free of any
/// package-specific type so the domain stays independent of the implementation.
class DeviceCredentialsStorageException implements Exception {
  const DeviceCredentialsStorageException([this.debugDetail]);

  final String? debugDetail;

  @override
  String toString() =>
      'DeviceCredentialsStorageException(${debugDetail ?? 'no detail'})';
}
