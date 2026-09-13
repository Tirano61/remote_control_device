import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/device/domain/entities/device_credentials.dart';
import 'package:remote_control_device/features/device/domain/entities/device_session.dart';
import 'package:remote_control_device/features/device/domain/repositories/device_auth_repository.dart';

/// Exchanges the stored permanent credential for a Device JWT.
class AuthenticateDevice {
  const AuthenticateDevice(this._repository);

  final DeviceAuthRepository _repository;

  Future<Result<DeviceSession>> call(DeviceCredentials credentials) =>
      _repository.login(credentials);
}
