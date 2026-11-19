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

/// The single deferred retry came due: open a new socket — after renewing the
/// Device JWT when [renew], with the current one otherwise. Tagged with the
/// generation that scheduled it, so a timer that outlived its generation does
/// nothing.
final class _RetryDue extends DeviceRealtimeEvent {
  const _RetryDue(this.generation, {required this.renew});

  final int generation;
  final bool renew;

  @override
  List<Object?> get props => [generation, renew];
}
