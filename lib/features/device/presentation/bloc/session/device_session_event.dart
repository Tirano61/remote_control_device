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

/// User asked to try again after a connectivity/backend error.
final class DeviceSessionRetryRequested extends DeviceSessionEvent {
  const DeviceSessionRetryRequested();
}

/// The enrollment flow stored a fresh credential; authenticate with it.
final class DeviceSessionEnrollmentCompleted extends DeviceSessionEvent {
  const DeviceSessionEnrollmentCompleted();
}

/// The realtime layer established that the permanent credential is no longer
/// accepted by the backend. Same consequence as a rejected login at startup.
final class DeviceSessionCredentialRejected extends DeviceSessionEvent {
  const DeviceSessionCredentialRejected();
}
