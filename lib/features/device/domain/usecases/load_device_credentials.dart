import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/device/domain/entities/device_credentials.dart';
import 'package:remote_control_device/features/device/domain/storage/device_credentials_storage.dart';

/// Reads the permanent credential at startup.
///
/// `Ok(null)` means "not enrolled"; an `Err` means the store itself failed and
/// must not be mistaken for an empty store — that distinction is what prevents
/// a storage glitch from silently sending the device back to enrollment.
class LoadDeviceCredentials {
  const LoadDeviceCredentials(this._storage);

  final DeviceCredentialsStorage _storage;

  Future<Result<DeviceCredentials?>> call() async {
    try {
      return Ok(await _storage.read());
    } on DeviceCredentialsStorageException catch (error) {
      return Err(StorageFailure(debugDetail: error.debugDetail));
    }
  }
}
