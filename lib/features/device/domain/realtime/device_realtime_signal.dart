import 'package:equatable/equatable.dart';
import 'package:remote_control_device/features/device/domain/entities/device_realtime_confirmation.dart';

/// Transport-agnostic facts reported by the realtime connection.
///
/// These are deliberately *not* Socket.IO events: nothing above the data layer
/// should know that the transport is Socket.IO, and no signal ever carries a
/// token, a raw error object or a payload the client did not validate.
sealed class DeviceRealtimeSignal extends Equatable {
  const DeviceRealtimeSignal();

  @override
  List<Object?> get props => const [];
}

/// The handshake succeeded and the namespace accepted the connection.
final class RealtimeConnected extends DeviceRealtimeSignal {
  const RealtimeConnected();
}

/// `device:connected` arrived with a payload that passed validation.
final class RealtimeIdentityConfirmed extends DeviceRealtimeSignal {
  const RealtimeIdentityConfirmed(this.confirmation);

  final DeviceRealtimeConfirmation confirmation;

  @override
  List<Object?> get props => [confirmation];
}

/// An established connection dropped. The transport retries on its own.
final class RealtimeDisconnected extends DeviceRealtimeSignal {
  const RealtimeDisconnected();
}

/// The transport is retrying after having lost the connection.
final class RealtimeReconnectAttempt extends DeviceRealtimeSignal {
  const RealtimeReconnectAttempt();
}

/// A connection attempt failed for a transport reason: no network, DNS,
/// timeout, backend down. The credential is not implicated.
final class RealtimeConnectFailed extends DeviceRealtimeSignal {
  const RealtimeConnectFailed();
}

/// The namespace middleware refused the handshake.
///
/// REALTIME.md makes every rejection reason indistinguishable — expired token,
/// deactivated device and revoked credential all answer the same generic
/// `Unauthorized` — so this signal only means "the token presented was not
/// accepted". Which of the two it is can only be established by asking
/// `POST /device-auth/login` with the permanent credential.
///
/// The transport does **not** retry by itself after this: a namespace
/// rejection destroys the socket.
final class RealtimeHandshakeRejected extends DeviceRealtimeSignal {
  const RealtimeHandshakeRejected();
}
