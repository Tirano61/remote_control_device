part of 'device_session_bloc.dart';

/// Application-wide device state. Every screen derives from this single
/// decision point instead of each one deciding for itself.
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

/// The backend rejected the permanent credential (`401`). Local credentials
/// have already been wiped; the device must be activated again.
final class DeviceSessionReEnrollmentRequired extends DeviceSessionState {
  const DeviceSessionReEnrollmentRequired();
}

/// The backend could not be reached or answered unexpectedly. Credentials are
/// intentionally preserved and the user can retry — a missing network is never
/// a reason to send a device back to enrollment.
final class DeviceSessionNetworkError extends DeviceSessionState {
  const DeviceSessionNetworkError(this.failure);

  final Failure failure;

  @override
  List<Object?> get props => [failure];
}
