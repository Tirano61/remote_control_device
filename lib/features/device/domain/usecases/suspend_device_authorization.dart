import 'package:remote_control_device/features/device/domain/repositories/device_auth_repository.dart';

/// Withdraws whatever this process holds that authorises the device: the
/// in-memory Device JWT.
///
/// Deliberately does **not** touch the permanent credential in secure storage.
/// No answer the backend can give proves that credential is gone for good —
/// `DEVICE_CREDENTIAL_REJECTED` is also what a temporarily deactivated device
/// gets — and an ambiguous answer proves even less. The credential is replaced
/// only by a new enrollment the user starts, and only once that enrollment has
/// succeeded.
///
/// Keeping the credential is not keeping authorisation: without a Device JWT no
/// authenticated request is sent, and nothing protected runs until a new login
/// is accepted and confirmed by `GET /device-auth/check-status`.
class SuspendDeviceAuthorization {
  const SuspendDeviceAuthorization(this._authRepository);

  final DeviceAuthRepository _authRepository;

  void call() => _authRepository.endSession();
}
