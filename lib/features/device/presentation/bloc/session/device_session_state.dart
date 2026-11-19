part of 'device_session_bloc.dart';

/// Application-wide device state. Every screen derives from this single
/// decision point instead of each one deciding for itself.
///
/// Only [DeviceSessionReady] authorises anything. Every other state — including
/// the ones that keep the credential in secure storage — means there is no
/// Device JWT in memory, the realtime channel is closed and no support request,
/// remote session or remote-control command is acted on.
sealed class DeviceSessionState extends Equatable {
  const DeviceSessionState();

  @override
  List<Object?> get props => [];
}

/// Before the startup sequence has begun.
final class DeviceSessionInitial extends DeviceSessionState {
  const DeviceSessionInitial();
}

/// Reading the permanent credential from secure storage.
final class DeviceSessionCheckingLocalCredentials extends DeviceSessionState {
  const DeviceSessionCheckingLocalCredentials();
}

/// No local credential: the device has never been activated here.
final class DeviceSessionNotEnrolled extends DeviceSessionState {
  const DeviceSessionNotEnrolled();
}

/// Running `POST /device-auth/login` + `GET /device-auth/check-status`.
final class DeviceSessionAuthenticating extends DeviceSessionState {
  const DeviceSessionAuthenticating();
}

/// Backend confirmed the Device JWT. The device is operational.
final class DeviceSessionReady extends DeviceSessionState {
  const DeviceSessionReady(this.device);

  final DeviceIdentity device;

  @override
  List<Object?> get props => [device];
}

/// `POST /device-auth/login` answered `401 DEVICE_CREDENTIAL_REJECTED`.
///
/// Authorisation is withdrawn, but the credential is **kept** in secure
/// storage: the contract does not say whether the device was deactivated (the
/// same credential works again once an admin reactivates it) or the credential
/// was replaced (a new enrollment is needed). Nothing is retried on its own;
/// the user can retry explicitly, or start a new enrollment.
final class DeviceSessionCredentialRefused extends DeviceSessionState {
  const DeviceSessionCredentialRefused();
}

/// The user chose to enroll again after a refusal. The previous credential
/// stays stored until the new enrollment succeeds and replaces it; cancelling
/// returns to [DeviceSessionCredentialRefused].
final class DeviceSessionReEnrolling extends DeviceSessionState {
  const DeviceSessionReEnrolling();
}

/// Authentication could not be confirmed: the backend was unreachable or
/// answered something that confirms nothing — a 5xx, a redirect, a malformed
/// body, a `401` without `DEVICE_CREDENTIAL_REJECTED` — or the secure store
/// could not be read. The credential is preserved, the device is not
/// authorised, and the attempt is repeated on a bounded backoff and on demand.
final class DeviceSessionAuthenticationUnavailable extends DeviceSessionState {
  const DeviceSessionAuthenticationUnavailable(this.failure);

  final Failure failure;

  @override
  List<Object?> get props => [failure];
}

/// Whether [state] means that whatever the device was doing on the backend's
/// authority — a support request, a remote session, the screen, remote control
/// — must stop and be forgotten locally.
///
/// [DeviceSessionReady] is the only state that authorises anything, but the
/// transient startup states are not listed: they never follow READY except
/// through an explicit retry, and they end in one of the states below anyway.
bool withdrawsDeviceAuthorization(DeviceSessionState state) =>
    state is DeviceSessionCredentialRefused ||
    state is DeviceSessionReEnrolling ||
    state is DeviceSessionAuthenticationUnavailable ||
    state is DeviceSessionNotEnrolled;
