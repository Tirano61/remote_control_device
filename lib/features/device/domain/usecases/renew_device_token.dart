import 'package:equatable/equatable.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/device/domain/entities/device_credentials.dart';
import 'package:remote_control_device/features/device/domain/entities/device_session.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';

/// Outcome of trying to mint a fresh Device JWT from the stored permanent
/// credential.
///
/// The three cases exist because they demand three different reactions, and
/// collapsing any two of them would either strand a working device offline or
/// wipe a perfectly valid credential over a flaky network.
sealed class DeviceTokenRenewal extends Equatable {
  const DeviceTokenRenewal();

  @override
  List<Object?> get props => const [];
}

/// A new Device JWT was issued and is already installed as the current session
/// token; the next handshake will use it.
final class DeviceTokenRenewed extends DeviceTokenRenewal {
  const DeviceTokenRenewed(this.token);

  final String token;

  @override
  List<Object?> get props => [token];

  /// Redacted on purpose: the Device JWT must never reach a log.
  @override
  String toString() => 'DeviceTokenRenewed(token: <redacted>)';
}

/// The backend answered `401` to `POST /device-auth/login`, so the *permanent*
/// credential — not merely the expired JWT — is no longer accepted. The device
/// has to be enrolled again.
///
/// Wiping the credential is not done here: that belongs to the session, which
/// owns the local installation identity.
final class DeviceTokenRejected extends DeviceTokenRenewal {
  const DeviceTokenRejected();
}

/// The backend could not be asked at all (offline, timeout, 5xx) or the secure
/// store could not be read. Nothing is known about the credential, so it must
/// be preserved and the attempt retried later.
final class DeviceTokenRenewalUnavailable extends DeviceTokenRenewal {
  const DeviceTokenRenewalUnavailable(this.failure);

  final Failure failure;

  @override
  List<Object?> get props => [failure];
}

/// Re-authenticates the device with the stored `deviceId` + `deviceSecret`.
///
/// Used when the temporary Device JWT is no longer accepted — most visibly when
/// a Socket.IO handshake is refused after the app has been running longer than
/// the 24h token lifetime.
class RenewDeviceToken {
  const RenewDeviceToken({
    required LoadDeviceCredentials loadDeviceCredentials,
    required AuthenticateDevice authenticateDevice,
  }) : _loadDeviceCredentials = loadDeviceCredentials,
       _authenticateDevice = authenticateDevice;

  final LoadDeviceCredentials _loadDeviceCredentials;
  final AuthenticateDevice _authenticateDevice;

  Future<DeviceTokenRenewal> call() async {
    final credentialsResult = await _loadDeviceCredentials();
    switch (credentialsResult) {
      case Err<DeviceCredentials?>(:final failure):
        return DeviceTokenRenewalUnavailable(failure);
      case Ok<DeviceCredentials?>(value: null):
        // Nothing left to authenticate with: the installation identity is gone.
        return const DeviceTokenRejected();
      case Ok<DeviceCredentials?>(:final value?):
        return _login(value);
    }
  }

  Future<DeviceTokenRenewal> _login(DeviceCredentials credentials) async {
    final result = await _authenticateDevice(credentials);
    return switch (result) {
      Ok<DeviceSession>(:final value) => DeviceTokenRenewed(value.token),
      Err<DeviceSession>(failure: AuthFailure()) => const DeviceTokenRejected(),
      Err<DeviceSession>(:final failure) => DeviceTokenRenewalUnavailable(
        failure,
      ),
    };
  }
}
