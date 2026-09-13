import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/device/domain/repositories/device_auth_repository.dart';
import 'package:remote_control_device/features/device/domain/storage/device_credentials_storage.dart';

/// Wipes the local installation identity: permanent credential plus the
/// in-memory Device JWT issued from it.
///
/// Called only when the backend has actually rejected the credential — never
/// because the backend was unreachable.
class ClearDeviceCredentials {
  const ClearDeviceCredentials({
    required DeviceCredentialsStorage credentialsStorage,
    required DeviceAuthRepository authRepository,
  }) : _credentialsStorage = credentialsStorage,
       _authRepository = authRepository;

  final DeviceCredentialsStorage _credentialsStorage;
  final DeviceAuthRepository _authRepository;

  Future<Result<void>> call() async {
    _authRepository.endSession();
    try {
      await _credentialsStorage.clear();
      return const Ok(null);
    } on DeviceCredentialsStorageException catch (error) {
      return Err(StorageFailure(debugDetail: error.debugDetail));
    }
  }
}
