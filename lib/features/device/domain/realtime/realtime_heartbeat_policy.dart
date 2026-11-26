import 'package:equatable/equatable.dart';

/// The heartbeat the backend announced for one connection.
///
/// Read from the Engine.IO handshake (`OPEN` packet) of that very connection,
/// never configured here: REALTIME.md, "Heartbeat and dead-connection
/// detection", says the server sends both values to every client and that
/// clients configure nothing. With the backend's defaults they are 10 s / 10 s.
///
/// The server sends a `PING` [pingInterval] after the previous `PONG` reached
/// it, so a healthy connection delivers one about every [pingInterval] plus a
/// round trip. It gives up on a `PONG` [pingTimeout] after its `PING`.
final class RealtimeHeartbeatPolicy extends Equatable {
  const RealtimeHeartbeatPolicy({
    required this.pingInterval,
    required this.pingTimeout,
  });

  /// The values of a handshake, as the transport holds them (milliseconds),
  /// or `null` when either is missing or not a positive integer. A connection
  /// without a policy is not watched: see `HeartbeatWatchdog.start`.
  static RealtimeHeartbeatPolicy? fromHandshake({
    required Object? pingIntervalMs,
    required Object? pingTimeoutMs,
  }) {
    if (pingIntervalMs is! int || pingTimeoutMs is! int) return null;
    if (pingIntervalMs <= 0 || pingTimeoutMs <= 0) return null;
    return RealtimeHeartbeatPolicy(
      pingInterval: Duration(milliseconds: pingIntervalMs),
      pingTimeout: Duration(milliseconds: pingTimeoutMs),
    );
  }

  final Duration pingInterval;
  final Duration pingTimeout;

  @override
  List<Object?> get props => [pingInterval, pingTimeout];

  @override
  String toString() =>
      '${pingInterval.inMilliseconds}/${pingTimeout.inMilliseconds} ms';
}
