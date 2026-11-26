part of 'device_realtime_bloc.dart';

/// Why the realtime channel is closed.
enum DeviceRealtimeStopCause {
  /// There is no device session to authenticate a socket with, or the app asked
  /// for the channel to be closed.
  noSession,

  /// `POST /device-auth/login` answered `401 DEVICE_CREDENTIAL_REJECTED`: the
  /// permanent credential itself is not accepted now. The session layer reacts
  /// by withdrawing authorisation; the credential stays in secure storage and
  /// nothing is retried until the user asks.
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

/// The transport still reports the connection as up, but its Engine.IO
/// heartbeat is overdue: no `PING` within `pingInterval` + a tolerance (13 s
/// with the backend's 10/10). See `HeartbeatWatchdog`.
///
/// For everything that hangs on the channel this is **not connected**: the
/// remote session's authority is suspended exactly as on a real
/// disconnection, the screen is held back and commands are refused. It is a
/// suspicion, not a verdict, so nothing is torn down here and the socket is
/// left to the transport:
///
/// ```text
/// a PING arrives          ──> DeviceRealtimeConnected again. That is all it
///                             does: the session still needs a REST read made
///                             after it, as after any reconnection
/// the transport gives up  ──> DeviceRealtimeReconnecting, as always
/// neither, for too long   ──> a new socket (DeviceRealtimeReconnecting)
/// ```
final class DeviceRealtimeHeartbeatOverdue extends DeviceRealtimeState {
  const DeviceRealtimeHeartbeatOverdue({this.confirmation});

  /// Kept from the connection it suspects, so that it is not lost if the
  /// heartbeat comes back on the same socket.
  final DeviceRealtimeConfirmation? confirmation;

  @override
  List<Object?> get props => [confirmation];
}

/// A connection that had been established was lost and is being retried.
final class DeviceRealtimeReconnecting extends DeviceRealtimeState {
  const DeviceRealtimeReconnecting();
}

/// A connection attempt failed and none has succeeded yet in this session.
///
/// Always transient: the transport or the bloc's own backoff will try again.
/// Only a confirmed refusal of the credential stops the channel, and that is
/// [DeviceRealtimeDisconnected] with [DeviceRealtimeStopCause.credentialRejected].
final class DeviceRealtimeConnectionError extends DeviceRealtimeState {
  const DeviceRealtimeConnectionError();
}
