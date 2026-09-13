part of 'device_realtime_bloc.dart';

/// Why the realtime channel is closed.
enum DeviceRealtimeStopCause {
  /// There is no device session to authenticate a socket with, or the app asked
  /// for the channel to be closed.
  noSession,

  /// `POST /device-auth/login` answered `401`: the permanent credential itself
  /// is no longer accepted. The session layer reacts by wiping the local
  /// installation identity and requiring re-enrollment.
  credentialRejected,
}

/// State of the Socket.IO channel — deliberately separate from
/// [DeviceSessionState].
///
/// A device can be authenticated over HTTP and momentarily unreachable over the
/// socket; that is a normal tablet on a weak network, not a broken session.
/// Conflating the two would send a perfectly enrolled device back to the
/// activation form every time the Wi-Fi blinks.
sealed class DeviceRealtimeState extends Equatable {
  const DeviceRealtimeState();

  @override
  List<Object?> get props => const [];
}

/// No connection and none wanted.
final class DeviceRealtimeDisconnected extends DeviceRealtimeState {
  const DeviceRealtimeDisconnected({
    this.cause = DeviceRealtimeStopCause.noSession,
  });

  final DeviceRealtimeStopCause cause;

  @override
  List<Object?> get props => [cause];
}

/// Opening the first connection of this session. No attempt has failed yet.
final class DeviceRealtimeConnecting extends DeviceRealtimeState {
  const DeviceRealtimeConnecting();
}

/// The handshake was accepted. The backend now reports this device as `ONLINE`.
final class DeviceRealtimeConnected extends DeviceRealtimeState {
  const DeviceRealtimeConnected({this.confirmation});

  /// Set once `device:connected` arrives. It only confirms the identity the
  /// backend resolved from the token — it never replaces the identity obtained
  /// from `GET /device-auth/check-status`.
  final DeviceRealtimeConfirmation? confirmation;

  @override
  List<Object?> get props => [confirmation];
}

/// A connection that had been established was lost and is being retried.
final class DeviceRealtimeReconnecting extends DeviceRealtimeState {
  const DeviceRealtimeReconnecting();
}

/// A connection attempt failed and none has succeeded yet in this session.
final class DeviceRealtimeConnectionError extends DeviceRealtimeState {
  const DeviceRealtimeConnectionError({this.retrying = true});

  /// `false` when nothing is trying any more — the client refused to keep
  /// re-authenticating in a loop. The user-facing text is the same either way;
  /// only a new device session restarts the channel.
  final bool retrying;

  @override
  List<Object?> get props => [retrying];
}
