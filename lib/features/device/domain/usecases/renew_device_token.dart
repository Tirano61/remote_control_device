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

/// `POST /device-auth/login` answered `401 DEVICE_CREDENTIAL_REJECTED`: the
/// backend refused the *permanent* credential, not merely an expired JWT. Also
/// what an empty secure store yields — there is nothing left to log in with.
///
/// It withdraws authorisation; it does not wipe anything. The contract cannot
/// tell a deactivated device from a replaced credential, and a deactivated one
/// is accepted again, with the same credential, once an admin reactivates it.
/// What happens next belongs to the session, which owns the local identity.
final class DeviceTokenRejected extends DeviceTokenRenewal {
  const DeviceTokenRejected();
}

/// The backend could not confirm anything: offline, timeout, 5xx, a redirect,
/// a malformed body, a `401` without `DEVICE_CREDENTIAL_REJECTED` (a proxy or a
/// private tunnel answers those too), or the secure store could not be read.
/// Nothing is known about the credential, so it is preserved and the attempt
/// retried later. The device is not authenticated in the meantime.
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
///
/// **One login at a time, application-wide.** The REST side and the Socket.IO
/// side share this instance, and both can discover an expired token at the same
/// moment. A call made while a login is on the wire gets that login's answer
/// instead of starting another: one request reaches the backend, and no two
/// answers race to install their token, so an earlier login can never land
/// after — and replace — a later one.
class RenewDeviceToken {
  RenewDeviceToken({
    required LoadDeviceCredentials loadDeviceCredentials,
    required AuthenticateDevice authenticateDevice,
  }) : _loadDeviceCredentials = loadDeviceCredentials,
       _authenticateDevice = authenticateDevice;

  final LoadDeviceCredentials _loadDeviceCredentials;
  final AuthenticateDevice _authenticateDevice;

  Future<DeviceTokenRenewal>? _inFlight;

  Future<DeviceTokenRenewal> call() =>
      _inFlight ??= _renew().whenComplete(() => _inFlight = null);

  Future<DeviceTokenRenewal> _renew() async {
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
      // Only the code confirms a rejection. A bare 401 here is ambiguous and
      // falls through to "unavailable" with everything else.
      Err<DeviceSession>(failure: CredentialRejectedFailure()) =>
        const DeviceTokenRejected(),
      Err<DeviceSession>(:final failure) => DeviceTokenRenewalUnavailable(
        failure,
      ),
    };
  }
}
