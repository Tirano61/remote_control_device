import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/device/domain/entities/device_credentials.dart';
import 'package:remote_control_device/features/device/domain/entities/device_identity.dart';
import 'package:remote_control_device/features/device/domain/entities/device_session.dart';

/// `POST /device-auth/login` and `GET /device-auth/check-status`.
abstract interface class DeviceAuthRepository {
  /// Exchanges the permanent credential for a Device JWT and installs that
  /// token as the current session token.
  ///
  /// Every rejection reason (unknown device, inactive device, revoked
  /// credential, wrong secret) answers the same `401` and surfaces as an
  /// `AuthFailure`.
  Future<Result<DeviceSession>> login(DeviceCredentials credentials);

  /// Validates the current Device JWT and returns the authenticated device.
  /// Does not renew the token — renewal goes through [login].
  Future<Result<DeviceIdentity>> checkStatus();

  /// Drops the in-memory Device JWT. Does not touch the permanent credential.
  void endSession();
}
