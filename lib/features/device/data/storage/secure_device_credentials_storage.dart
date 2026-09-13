import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:remote_control_device/features/device/domain/entities/device_credentials.dart';
import 'package:remote_control_device/features/device/domain/storage/device_credentials_storage.dart';

/// Android-Keystore-backed implementation of [DeviceCredentialsStorage].
///
/// `flutter_secure_storage` 11 defaults to AES/GCM data encryption with the
/// storage key wrapped by an RSA key held in the Android Keystore, so the
/// `deviceSecret` never sits in plaintext in SharedPreferences, a file or a
/// database. This is the only place in the app that touches that package.
class SecureDeviceCredentialsStorage implements DeviceCredentialsStorage {
  const SecureDeviceCredentialsStorage({FlutterSecureStorage? secureStorage})
    : _storage = secureStorage ?? const FlutterSecureStorage();

  static const String deviceIdKey = 'device.id';
  static const String deviceSecretKey = 'device.secret';

  final FlutterSecureStorage _storage;

  @override
  Future<DeviceCredentials?> read() async {
    try {
      final deviceId = await _storage.read(key: deviceIdKey);
      final deviceSecret = await _storage.read(key: deviceSecretKey);

      // A half-written pair cannot authenticate; treat it as "not enrolled".
      if (deviceId == null ||
          deviceId.isEmpty ||
          deviceSecret == null ||
          deviceSecret.isEmpty) {
        return null;
      }

      return DeviceCredentials(deviceId: deviceId, deviceSecret: deviceSecret);
    } on Exception catch (error) {
      throw DeviceCredentialsStorageException('read failed: ${error.runtimeType}');
    }
  }

  @override
  Future<void> save(DeviceCredentials credentials) async {
    try {
      await _storage.write(key: deviceIdKey, value: credentials.deviceId);
      await _storage.write(key: deviceSecretKey, value: credentials.deviceSecret);
    } on Exception catch (error) {
      throw DeviceCredentialsStorageException('write failed: ${error.runtimeType}');
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: deviceIdKey);
      await _storage.delete(key: deviceSecretKey);
    } on Exception catch (error) {
      throw DeviceCredentialsStorageException('delete failed: ${error.runtimeType}');
    }
  }
}
