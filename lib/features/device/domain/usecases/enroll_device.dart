import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/device/domain/entities/device_activation.dart';
import 'package:remote_control_device/features/device/domain/repositories/device_enrollment_repository.dart';
import 'package:remote_control_device/features/device/domain/services/device_info_provider.dart';
import 'package:remote_control_device/features/device/domain/storage/device_credentials_storage.dart';

/// Activates this installation and persists the credential it receives.
///
/// The `deviceSecret` is delivered once and only by the activation call, so it
/// is written to secure storage as part of the same operation: an activation
/// whose credential could not be stored is reported as a failure, otherwise the
/// device would end up unable to authenticate and unable to re-activate with
/// the same code.
class EnrollDevice {
  const EnrollDevice({
    required DeviceEnrollmentRepository repository,
    required DeviceCredentialsStorage credentialsStorage,
    required DeviceInfoProvider deviceInfoProvider,
  }) : _repository = repository,
       _credentialsStorage = credentialsStorage,
       _deviceInfoProvider = deviceInfoProvider;

  final DeviceEnrollmentRepository _repository;
  final DeviceCredentialsStorage _credentialsStorage;
  final DeviceInfoProvider _deviceInfoProvider;

  Future<Result<DeviceActivation>> call({
    required String publicId,
    required String code,
  }) async {
    final technicalInfo = await _deviceInfoProvider.collect();

    final result = await _repository.activate(
      publicId: publicId,
      code: code,
      technicalInfo: technicalInfo,
    );

    return switch (result) {
      Err<DeviceActivation>() => result,
      Ok<DeviceActivation>(:final value) => await _persist(value),
    };
  }

  Future<Result<DeviceActivation>> _persist(DeviceActivation activation) async {
    try {
      await _credentialsStorage.save(activation.credentials);
      return Ok(activation);
    } on DeviceCredentialsStorageException catch (error) {
      return Err(StorageFailure(debugDetail: error.debugDetail));
    }
  }
}
