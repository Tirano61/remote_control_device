import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/device/domain/entities/device_identity.dart';
import 'package:remote_control_device/features/device/domain/repositories/device_auth_repository.dart';

/// Confirms with the backend — the authoritative side — that the freshly
/// obtained Device JWT is accepted, and returns the public device information.
class CheckDeviceStatus {
  const CheckDeviceStatus(this._repository);

  final DeviceAuthRepository _repository;

  Future<Result<DeviceIdentity>> call() => _repository.checkStatus();
}
