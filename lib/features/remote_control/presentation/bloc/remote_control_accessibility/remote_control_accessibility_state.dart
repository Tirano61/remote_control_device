part of 'remote_control_accessibility_bloc.dart';

final class RemoteControlAccessibilityState extends Equatable {
  const RemoteControlAccessibilityState([this.status]);

  /// `null` until the first read answers, so the screen does not ask the user
  /// to enable a service that may already be enabled.
  final RemoteControlAccessibilityStatus? status;

  @override
  List<Object?> get props => [status];
}
