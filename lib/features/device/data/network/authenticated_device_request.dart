import 'package:remote_control_device/core/network/api_exception.dart';
import 'package:remote_control_device/core/session/device_credential_revocation.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';

/// Runs a device-authenticated HTTP call and recovers, exactly once, from an
/// expired Device JWT.
///
/// The support endpoints are the first ones a tablet may call many hours after
/// boot, which is precisely when the 24h Device JWT is gone. A `401` there means
/// one of two very different things, and the difference cannot be read off the
/// response:
///
/// ```text
/// request ──401──> POST /device-auth/login with deviceId + deviceSecret
///                    ├── 200 ──> retry the request once, with the new JWT
///                    ├── 401 ──> the permanent credential is revoked:
///                    │           report it; the session requires enrollment
///                    └── offline/5xx ──> nothing learnt: credential preserved,
///                                        the call fails as retryable
/// ```
///
/// The renewal itself is [RenewDeviceToken], the same use case the Socket.IO
/// layer uses, so there is one implementation of "re-authenticate the device"
/// and one implementation of "the credential was revoked" in the application.
///
/// **One retry, never more.** The retry is a single extra call in a `catch`
/// block, so a request that is refused again with the freshly minted token
/// simply propagates: there is no loop to bound because there is no loop.
class AuthenticatedDeviceRequest {
  AuthenticatedDeviceRequest({
    required RenewDeviceToken renewDeviceToken,
    required DeviceCredentialRevocation revocation,
  }) : _renewDeviceToken = renewDeviceToken,
       _revocation = revocation;

  final RenewDeviceToken _renewDeviceToken;
  final DeviceCredentialRevocation _revocation;

  /// A renewal already under way. Several calls failing at once must produce
  /// one login, not one login each.
  Future<DeviceTokenRenewal>? _renewal;

  /// Runs [request], renewing the Device JWT and repeating it once if the
  /// backend answered `401`.
  ///
  /// [request] must read the token from the store at call time — which the
  /// `DeviceAuthInterceptor` does — so that the second attempt presents the new
  /// JWT and not the one that was just refused.
  Future<T> run<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on UnauthorizedApiException {
      switch (await _renew()) {
        case DeviceTokenRenewed():
          return await request();
        case DeviceTokenRejected():
          _revocation.report();
          rethrow;
        case DeviceTokenRenewalUnavailable(:final failure):
          throw TokenRenewalApiException(failure);
      }
    }
  }

  Future<DeviceTokenRenewal> _renew() {
    final pending = _renewal;
    if (pending != null) return pending;

    final renewal = _renewDeviceToken().whenComplete(() => _renewal = null);
    _renewal = renewal;
    return renewal;
  }
}
