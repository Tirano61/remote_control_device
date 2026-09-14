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

/// `support:assigned` arrived with a payload that passed validation: a
/// technician took the support request this device is waiting on.
///
/// It lives with the transport signals rather than in the support feature
/// because the `/devices` namespace is a single device-wide channel that
/// carries notices for several features; the feature that cares interprets it.
///
/// It carries **identifiers only, and no authority**. The contract states that
/// delivery is best-effort and the assignment is recovered with
/// `GET /support-requests/current` regardless, so the persistent representation
/// is what decides that a request is assigned and who the technician is. These
/// ids are here to match the notice against the state the client already holds
/// and to be logged safely — never to populate a screen.
final class RealtimeSupportAssigned extends DeviceRealtimeSignal {
  const RealtimeSupportAssigned({
    required this.supportRequestId,
    required this.technicianId,
  });

  final String supportRequestId;
  final String technicianId;

  @override
  List<Object?> get props => [supportRequestId, technicianId];
}

/// `remote-session:created` arrived with a payload that passed validation: a
/// technician started the assistance the user had already authorised.
///
/// Like [RealtimeSupportAssigned], it carries **identifiers only, and no
/// authority**. The contract is explicit that delivery is best-effort and that
/// the session is recovered with `GET /device/remote-sessions/current`
/// regardless, so the persisted session is what decides that one exists and
/// what its id is. In particular, the [remoteSessionId] here is never the id
/// this client closes: a session that can be ended is one that came back from
/// an authenticated REST read.
final class RealtimeRemoteSessionCreated extends DeviceRealtimeSignal {
  const RealtimeRemoteSessionCreated({
    required this.remoteSessionId,
    required this.supportRequestId,
    required this.technicianId,
  });

  final String remoteSessionId;
  final String supportRequestId;
  final String technicianId;

  @override
  List<Object?> get props => [remoteSessionId, supportRequestId, technicianId];
}

/// `remote-session:closed` arrived: the technician ended the assistance.
///
/// A cue, not a verdict. The tablet does not drop its session because this
/// arrived — it re-reads `GET /device/remote-sessions/current` and finds
/// nothing, which is what actually ends the session on screen. The event is
/// never emitted for a device-initiated close.
///
/// `endedBy` travels in the payload and is deliberately not carried: nothing in
/// this client branches on who closed a session, and a value it does not act on
/// has no business crossing into the domain.
final class RealtimeRemoteSessionClosed extends DeviceRealtimeSignal {
  const RealtimeRemoteSessionClosed(this.remoteSessionId);

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
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
