part of 'remote_control_accessibility_bloc.dart';

sealed class RemoteControlAccessibilityEvent extends Equatable {
  const RemoteControlAccessibilityEvent();

  @override
  List<Object?> get props => const [];
}

/// Reads the service's status and starts following it.
final class RemoteControlAccessibilityStarted
    extends RemoteControlAccessibilityEvent {
  const RemoteControlAccessibilityStarted();
}

/// Internal. Android reported the service connected or disconnected.
final class RemoteControlAccessibilityStatusChanged
    extends RemoteControlAccessibilityEvent {
  const RemoteControlAccessibilityStatusChanged(this.status);

  final RemoteControlAccessibilityStatus status;

  @override
  List<Object?> get props => [status];
}

/// The user pressed HABILITAR CONTROL REMOTO. Opens Android's settings and does
/// nothing else: enabling the service is the user's to do, there.
final class RemoteControlAccessibilitySettingsRequested
    extends RemoteControlAccessibilityEvent {
  const RemoteControlAccessibilitySettingsRequested();
}
