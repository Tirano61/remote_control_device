part of 'signaling_bloc.dart';

/// Whether this device's socket is in a remote session's signaling room.
///
/// Deliberately a different thing from [RemoteSessionState], and the difference
/// is the whole point of this file:
///
/// ```text
/// RemoteSession CONNECTING   a row in the backend database, read over REST.
///                            It survives a lost socket, a restart and a night
///                            with the tablet asleep.
///
/// SignalingJoined            a room membership on one Socket.IO connection.
///                            It dies with that connection, every time, and is
///                            never persisted anywhere.
/// ```
///
/// A session can be `CONNECTING` for hours with signaling joined, not joined
/// and joined again in between; nothing here ever moves the session, and the
/// session never claims anything about the room. In particular, signaling never
/// makes a session `ACTIVE` — the contract says so explicitly, and no backend
/// path writes that transition today.
sealed class SignalingState extends Equatable {
  const SignalingState();

  @override
  List<Object?> get props => const [];
}

/// Not joined, and not trying to be.
///
/// The state whenever there is nothing to join — no live session — and the
/// state a lost connection returns to: a fresh socket carries no joined
/// session, so the previous join is simply gone. It says nothing about the
/// remote session, which stays exactly where the backend put it.
final class SignalingIdle extends SignalingState {
  const SignalingIdle();
}

/// `remote-session:join` was emitted and its ACK has not arrived yet.
final class SignalingJoining extends SignalingState {
  const SignalingJoining(this.remoteSessionId);

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// The ACK said `joined: true`.
///
/// This is the one state in which `webrtc:*` may be emitted, and only for
/// [remoteSessionId]: the backend stores the joined session on the socket and
/// authorises every relayed message against it, so anything else would be
/// answered `NOT_JOINED`.
final class SignalingJoined extends SignalingState {
  const SignalingJoined(this.remoteSessionId, {required this.peerJoined});

  /// Echoed by the backend and checked against what was asked for. It is also
  /// the filter applied to every incoming message.
  final String remoteSessionId;

  /// Whether the technician's socket is in the same session room.
  ///
  /// Starts as whatever the join ACK said and turns `true` on
  /// `remote-session:peer-joined`. It never turns back: the contract has no
  /// peer-left notice, so `true` here means "was seen to be there", which is
  /// the honest reading and the only one the backend supports.
  ///
  /// Nothing in this application *acts* on it. The device is the answerer, and
  /// creating a peer connection because the technician is ready would make both
  /// ends offer at once. It is readiness for the user and for diagnostics; the
  /// negotiation still starts at `webrtc:offer` and nowhere else.
  final bool peerJoined;

  @override
  List<Object?> get props => [remoteSessionId, peerJoined];
}

/// Signaling is not usable for this session, and is not being retried on its
/// own.
///
/// Reached when a join was refused or went unanswered, and when a relay was
/// answered `UNAUTHORIZED` — the backend re-validates every message, so that
/// answer means the session moved on while the room membership stayed behind.
///
/// Staying here is deliberate. An attempt that failed and is immediately
/// repeated against unchanged circumstances fails identically, so the client
/// waits for something real to change — a new socket, a different session, the
/// session ending, or the user retrying — rather than spinning.
///
/// [error] is `null` when no ACK came back at all, which is not the same as a
/// refusal: one is the backend's verdict, the other the absence of one.
final class SignalingUnavailable extends SignalingState {
  const SignalingUnavailable(this.remoteSessionId, {this.error});

  final String remoteSessionId;
  final SignalingErrorCode? error;

  @override
  List<Object?> get props => [remoteSessionId, error];
}
