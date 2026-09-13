part of 'device_realtime_bloc.dart';

sealed class DeviceRealtimeEvent extends Equatable {
  const DeviceRealtimeEvent();

  @override
  List<Object?> get props => const [];
}

/// The device holds a validated session: open the realtime channel.
///
/// Carries no token. The Device JWT is read from the [DeviceTokenStore] at the
/// moment the connection is opened, so it can never go stale inside a queued
/// event and can never surface in a bloc observer or a state dump.
final class DeviceRealtimeStartRequested extends DeviceRealtimeEvent {
  const DeviceRealtimeStartRequested();
}

/// The device no longer holds a valid session: release the realtime channel.
final class DeviceRealtimeStopRequested extends DeviceRealtimeEvent {
  const DeviceRealtimeStopRequested();
}

/// Something happened on the transport.
final class _SignalReceived extends DeviceRealtimeEvent {
  const _SignalReceived(this.signal);

  final DeviceRealtimeSignal signal;

  @override
  List<Object?> get props => [signal];
}

/// The deferred retry of a Device JWT renewal that could not reach the backend.
final class _ReauthRetryDue extends DeviceRealtimeEvent {
  const _ReauthRetryDue();
}
