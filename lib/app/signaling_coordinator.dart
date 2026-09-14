import 'dart:async';

import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_error_code.dart';
import 'package:remote_control_device/features/signaling/presentation/bloc/signaling/signaling_bloc.dart';

/// Decides when this device joins a remote session's signaling room.
///
/// The contract makes the condition a conjunction of two facts owned by two
/// different blocs, which is exactly why neither of them can decide it:
///
/// ```text
/// DeviceRealtimeConnected               (the socket exists)
///            +
/// RemoteSession CONNECTING or ACTIVE    (the backend has a live session)
///            ↓
///   remote-session:join
/// ```
///
/// Either fact falling away resets signaling — and nothing more. A socket that
/// dropped does not end the assistance; a session that ended does not close the
/// socket. The one thing that happens is that the room membership, which never
/// survives its socket anyway, stops being claimed.
///
/// Everything is expressed as a change of that pair:
///
/// ```text
/// (connected, sessionId)  became (true,  id)   ──> join id
/// (connected, sessionId)  became (true,  null) ──> signaling session ended
/// (connected, sessionId)  became (false, ...)  ──> signaling connection lost
/// ```
///
/// Every one of those is idempotent, which is what makes repetition harmless.
/// The remote session is re-read on every reconnection, on
/// `remote-session:created`, and when a support request reaches `ACCEPTED`;
/// each read re-emits a state that usually says exactly what the previous one
/// said, and the announcement that follows finds `SignalingBloc` already in it.
/// Duplicate suppression therefore lives in one place — the signaling state
/// itself — instead of being half-implemented here and half there.
///
/// It also carries the one arrow pointing back: a join the backend refused for
/// an ownership or availability reason means this client's idea of the session
/// is stale, so the session is re-read. That is reconciliation, not retry —
/// `SignalingBloc` stays in [SignalingUnavailable] until the *answer* changes
/// something.
class SignalingCoordinator {
  SignalingCoordinator({
    required DeviceRealtimeBloc realtimeBloc,
    required RemoteSessionBloc remoteSessionBloc,
    required SignalingBloc signalingBloc,
  }) : _realtimeBloc = realtimeBloc,
       _remoteSessionBloc = remoteSessionBloc,
       _signalingBloc = signalingBloc;

  final DeviceRealtimeBloc _realtimeBloc;
  final RemoteSessionBloc _remoteSessionBloc;
  final SignalingBloc _signalingBloc;

  StreamSubscription<DeviceRealtimeState>? _realtimeSubscription;
  StreamSubscription<RemoteSessionState>? _remoteSessionSubscription;
  StreamSubscription<SignalingState>? _signalingSubscription;

  bool _connected = false;
  String? _liveSessionId;

  void start() {
    _connected = _realtimeBloc.state is DeviceRealtimeConnected;
    _liveSessionId = _sessionIdOf(_remoteSessionBloc.state);
    // The current values count, not only future transitions: on a restart the
    // socket may already be up and the session already recovered by the time
    // this is wired.
    _evaluate();

    _realtimeSubscription = _realtimeBloc.stream.listen((state) {
      _connected = state is DeviceRealtimeConnected;
      _evaluate();
    });
    _remoteSessionSubscription = _remoteSessionBloc.stream.listen((state) {
      _liveSessionId = _sessionIdOf(state);
      _evaluate();
    });
    _signalingSubscription = _signalingBloc.stream.listen(_onSignalingState);
  }

  /// The id of a session that may be joined, or `null`.
  ///
  /// Only a live session qualifies, and `RemoteSessionLive` is precisely the
  /// backend's `CONNECTING`/`ACTIVE`. Everything else — no session, a state
  /// that could not be read, a cleared identity — is "nothing to join", which
  /// is the safe reading: a session this client cannot confirm is live is one
  /// whose room the backend would refuse anyway.
  static String? _sessionIdOf(RemoteSessionState state) => switch (state) {
    RemoteSessionLive(:final session) => session.id,
    _ => null,
  };

  void _evaluate() {
    final connected = _connected;
    final sessionId = _liveSessionId;

    if (!connected) {
      // A join never survives its socket, so this is a fact being recorded,
      // not a decision being taken.
      _signalingBloc.add(const SignalingConnectionLost());
      return;
    }
    if (sessionId == null) {
      _signalingBloc.add(const SignalingSessionEnded());
      return;
    }
    _signalingBloc.add(SignalingJoinRequested(sessionId));
  }

  void _onSignalingState(SignalingState state) {
    if (state is! SignalingUnavailable) return;

    switch (state.error) {
      case SignalingErrorCode.unauthorized:
      // The session does not exist, is CLOSED, or belongs to another device —
      // indistinguishable by design. It is emphatically *not* a statement
      // about the permanent credential: the socket's own handshake was
      // validated before any of this, so nothing here reports a revocation or
      // clears anything. What it means is that the session this client is
      // holding is not the one the backend has, and only the backend can say
      // which that is.
      case SignalingErrorCode.unavailable:
        // The peer namespace was not reachable. Transient server-side, and the
        // same question answers it: is this session still live?
        _remoteSessionBloc.add(const RemoteSessionSyncRequested());

      case SignalingErrorCode.invalidPayload:
      case SignalingErrorCode.notJoined:
      case SignalingErrorCode.unknown:
      case null:
        // INVALID_PAYLOAD is a contract or programming error on this side: the
        // backend will answer the same thing to the same payload, so re-reading
        // the session would only add a call to a bug. NOT_JOINED cannot answer
        // a join. `null` is a join whose ACK never came, which the next
        // connection retries on its own. None of them is reconcilable by
        // asking again, so none of them asks.
        return;
    }
  }

  Future<void> dispose() async {
    await _realtimeSubscription?.cancel();
    await _remoteSessionSubscription?.cancel();
    await _signalingSubscription?.cancel();
    _realtimeSubscription = null;
    _remoteSessionSubscription = null;
    _signalingSubscription = null;
  }
}
