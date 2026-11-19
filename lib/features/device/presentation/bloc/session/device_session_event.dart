part of 'device_session_bloc.dart';

sealed class DeviceSessionEvent extends Equatable {
  const DeviceSessionEvent();

  @override
  List<Object?> get props => [];
}

/// Emitted once when the app boots.
final class DeviceSessionStarted extends DeviceSessionEvent {
  const DeviceSessionStarted();
}

/// The user asked to try again — after authentication was unavailable, or
/// after the backend refused the credential (an admin may have reactivated the
/// device since).
final class DeviceSessionRetryRequested extends DeviceSessionEvent {
  const DeviceSessionRetryRequested();
}

/// The enrollment flow stored a fresh credential; authenticate with it.
final class DeviceSessionEnrollmentCompleted extends DeviceSessionEvent {
  const DeviceSessionEnrollmentCompleted();
}

/// Something running — the realtime channel or an authenticated REST call —
/// had its renewal login answered `401 DEVICE_CREDENTIAL_REJECTED`. Same
/// consequence as that answer at startup.
final class DeviceSessionCredentialRejected extends DeviceSessionEvent {
  const DeviceSessionCredentialRejected();
}

/// From a refusal, the user chose to activate the device again.
final class DeviceSessionReEnrollmentRequested extends DeviceSessionEvent {
  const DeviceSessionReEnrollmentRequested();
}

/// The user left the re-enrollment form without enrolling.
final class DeviceSessionReEnrollmentCancelled extends DeviceSessionEvent {
  const DeviceSessionReEnrollmentCancelled();
}

/// The backoff after an unavailable authentication ran out.
final class _AutomaticRetryDue extends DeviceSessionEvent {
  const _AutomaticRetryDue();
}
