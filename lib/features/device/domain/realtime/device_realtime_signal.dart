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

/// `remote-session:active` arrived: the technician reported that the remote
/// connection came up, and the backend wrote `ACTIVE` and `connectedAt`.
///
/// The typed notice the contract's minimal payload deserves — it carries the
/// one field the event has, and the same nothing-but-identifiers rule as its
/// siblings. The device takes no part in the transition: `/activate` belongs to
/// `remote_control_web` and is never called from here.
///
/// It is a **trigger**, not a state. `REALTIME.md` says so in as many words —
///
/// ```text
/// remote-session:active  ->  GET /device/remote-sessions/current
/// ```
///
/// — and that is the whole of what this signal causes. Delivery is best-effort,
/// nothing is replayed, and the event is emitted only on the real transition,
/// so a tablet that was offline when it fired must reach `ACTIVE` without it.
/// It does, because the read it would have triggered is the same read every
/// reconnection and every restart already makes.
final class RealtimeRemoteSessionActivated extends DeviceRealtimeSignal {
  const RealtimeRemoteSessionActivated(this.remoteSessionId);

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// `remote-session:closed` arrived: the technician — or the backend itself,
/// `endedBy: SYSTEM` — ended the assistance.
///
/// For the session the tablet holds, this is the one realtime notice that is
/// acted on before REST answers, and only in the safe direction: control is
/// withdrawn and the peer connection and the screen capture are taken down at
/// once. `GET /device/remote-sessions/current` is still read afterwards and
/// still decides what comes next; it can never bring the closed session back.
/// The event is never emitted for a device-initiated close.
///
/// [endedBy] is the raw `RemoteSessionEndedBy` token, or `null` when the
/// payload carried none. It is shown to the user and decides nothing: any
/// value, known or not, means the session is over.
final class RealtimeRemoteSessionClosed extends DeviceRealtimeSignal {
  const RealtimeRemoteSessionClosed(this.remoteSessionId, {this.endedBy});

  final String remoteSessionId;
  final String? endedBy;

  @override
  List<Object?> get props => [remoteSessionId, endedBy];
}

/// An established connection dropped. The transport retries on its own.
final class RealtimeDisconnected extends DeviceRealtimeSignal {
  const RealtimeDisconnected();
}

/// The backend closed the connection itself (`io server disconnect`).
///
/// Unlike [RealtimeDisconnected], the transport does **not** retry: a
/// server-initiated disconnection destroys the socket. The backend does this
/// when it withdraws the device's authorisation — an administrator
/// deactivating it, or a re-enrollment revoking the credential the token was
/// minted from — so the client must find out where it stands by
/// re-authenticating, not by waiting for a reconnection that never comes.
///
/// It is never emitted for a close the application asked for: the client
/// detaches its listeners before closing.
final class RealtimeServerDisconnected extends DeviceRealtimeSignal {
  const RealtimeServerDisconnected();
}

/// The transport is retrying after having lost the connection.
final class RealtimeReconnectAttempt extends DeviceRealtimeSignal {
  const RealtimeReconnectAttempt();
}

/// A connection attempt failed for a reason that is not one of the documented
/// refusals: no network, DNS, timeout, backend down — or a namespace refusal
/// with an unknown code, a malformed body or some other message. The credential
/// is not implicated.
final class RealtimeConnectFailed extends DeviceRealtimeSignal {
  const RealtimeConnectFailed({this.transportRetrying = true});

  /// Whether the transport will try again by itself. `false` when the failure
  /// destroyed the socket (a namespace-level `connect_error` does), in which
  /// case only the client can open a new one.
  final bool transportRetrying;

  @override
  List<Object?> get props => [transportRetrying];
}

/// The namespace middleware checked the token and refused it
/// (`DEVICE_AUTH_UNAUTHORIZED`, or the bare `Unauthorized` of a backend older
/// than the codes).
///
/// REALTIME.md makes every rejection reason indistinguishable — expired token,
/// deactivated device and revoked credential all answer the same — so this
/// signal only means "the token presented was not accepted". Whether the
/// credential itself is refused can only be established by asking
/// `POST /device-auth/login` with it, and only a `401` carrying
/// `DEVICE_CREDENTIAL_REJECTED` there says so.
///
/// The transport does **not** retry by itself after this: a namespace
/// rejection destroys the socket.
final class RealtimeHandshakeRejected extends DeviceRealtimeSignal {
  const RealtimeHandshakeRejected();
}

/// The namespace middleware could not check the token
/// (`DEVICE_AUTH_UNAVAILABLE`): the backend's database failed.
///
/// It says nothing about the token. It is not accepted — the handshake was
/// refused and no socket exists — and it is not refused either: the same token
/// may be accepted once the backend recovers, while a renewal would only reach
/// the same broken database. So the token is kept and presented again later.
/// It authorises nothing in the meantime.
///
/// Like [RealtimeHandshakeRejected], it destroys the socket.
final class RealtimeHandshakeUnavailable extends DeviceRealtimeSignal {
  const RealtimeHandshakeUnavailable();
}
