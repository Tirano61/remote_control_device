import 'dart:developer' as developer;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/load_current_remote_session.dart';

part 'remote_session_event.dart';
part 'remote_session_state.dart';

/// Owns the remote assistance session, under the same rule as the support
/// flow:
///
/// ```text
/// REST is the state. Realtime only says "look again".
/// ```
///
/// Every state this bloc emits comes from a remote-session payload the backend
/// returned. `remote-session:created` never produces [RemoteSessionConnecting]
/// by itself and `remote-session:closed` never produces [RemoteSessionIdle] by
/// itself — each produces a `GET /device/remote-sessions/current`, and *that*
/// answer decides. The price is one extra call per event; what it buys is that
/// a tablet which was asleep, offline, or simply restarted ends up in the same
/// state as one that received every event, because the recovery path and the
/// happy path are the same code.
///
/// The second rule is that nothing is ever *invented*. A call that fails
/// because the network is down leaves a live session exactly where it was: the
/// user is told the connection is being retried, never that the technician
/// hung up. Only the backend ends a session.
class RemoteSessionBloc extends Bloc<RemoteSessionEvent, RemoteSessionState> {
  RemoteSessionBloc({
    required LoadCurrentRemoteSession loadCurrentRemoteSession,
    required CloseRemoteSession closeRemoteSession,
  }) : _loadCurrentRemoteSession = loadCurrentRemoteSession,
       _closeRemoteSession = closeRemoteSession,
       super(const RemoteSessionInitial()) {
    on<RemoteSessionSyncRequested>(_onSyncRequested);
    on<RemoteSessionAnnounced>(_onAnnounced);
    on<RemoteSessionClosureAnnounced>(_onClosureAnnounced);
    on<RemoteSessionCloseRequested>(_onCloseRequested);
    on<RemoteSessionResetRequested>(_onResetRequested);
  }

  static const String _loggerName = 'remote-session';

  final LoadCurrentRemoteSession _loadCurrentRemoteSession;
  final CloseRemoteSession _closeRemoteSession;

  /// Bumped when the device identity is dropped. An answer that arrives after
  /// that belongs to a device this installation no longer is, so it is
  /// discarded instead of being written over the cleared state.
  int _generation = 0;

  // ----------------------------------------------------------------- syncing

  Future<void> _onSyncRequested(
    RemoteSessionSyncRequested event,
    Emitter<RemoteSessionState> emit,
  ) async {
    // A close already in flight will settle the state with the backend's own
    // answer; a sync racing it could only overwrite that with an older read.
    if (_closeInFlight) return;
    await _sync(emit);
  }

  Future<void> _onAnnounced(
    RemoteSessionAnnounced event,
    Emitter<RemoteSessionState> emit,
  ) async {
    if (_closeInFlight) return;

    final known = state;
    if (known is RemoteSessionLive &&
        known.session.id != event.remoteSessionId) {
      // Not a reason to distrust the answer that follows — the backend is asked
      // either way — but worth knowing: the local copy was already stale.
      _log('a session was announced other than the one held');
    }
    await _sync(emit);
  }

  Future<void> _onClosureAnnounced(
    RemoteSessionClosureAnnounced event,
    Emitter<RemoteSessionState> emit,
  ) async {
    if (_closeInFlight) return;

    final known = state;
    if (known is RemoteSessionLive &&
        known.session.id != event.remoteSessionId) {
      _log('a closure was announced for a session other than the one held');
    }
    // Deliberately the same handler as every other cue. The event says a
    // session ended; only the empty answer to this read ends it here.
    await _sync(emit);
  }

  /// Reads `/current` and adopts whatever it says.
  ///
  /// A known state never becomes *unknown* because the call failed. A live
  /// session stays live — a tablet that lost Wi-Fi must not tell the user the
  /// assistance is over — and a confirmed "no session" stays that way. Only a
  /// backend answer moves either.
  ///
  /// Callers that are themselves an operation — a close, or one that came back
  /// `404`/`409` — reach this directly: re-reading is the whole point of those
  /// paths, which is why the in-flight guard lives in the event handlers above
  /// rather than here.
  Future<void> _sync(
    Emitter<RemoteSessionState> emit, {
    Failure? reason,
  }) async {
    final generation = _generation;
    final known = state;
    if (known is RemoteSessionInitial || known is RemoteSessionUnavailable) {
      emit(const RemoteSessionLoading());
    }

    final result = await _loadCurrentRemoteSession();
    if (generation != _generation) return;

    switch (result) {
      case Ok<RemoteSession?>(:final value):
        emit(_stateFor(value, lastFailure: reason));
      case Err<RemoteSession?>(:final failure):
        emit(
          switch (known) {
            RemoteSessionLive(:final session) => _stateFor(
              session,
              lastFailure: reason,
            ),
            // "There is no session" was established by the backend once; a
            // re-read that could not reach it does not un-establish it.
            RemoteSessionIdle() => RemoteSessionIdle(lastFailure: reason),
            _ => RemoteSessionUnavailable(reason ?? failure),
          },
        );
    }
  }

  // ----------------------------------------------------------------- closing

  Future<void> _onCloseRequested(
    RemoteSessionCloseRequested event,
    Emitter<RemoteSessionState> emit,
  ) async {
    final current = state;
    // Nothing to close, or a close already under way. This is also the whole
    // double-tap protection: the state moves to `closing` before anything is
    // awaited, so a second press finds it and does nothing.
    if (current is! RemoteSessionLive || current.closing) return;

    final generation = _generation;
    final session = current.session;
    emit(_stateFor(session, closing: true));

    // The id comes from the state, which was built from an authenticated
    // response — never from the widget that raised the event, and never from a
    // realtime payload. The backend still checks ownership; this only makes
    // sure the client never invents an id to act on.
    final result = await _closeRemoteSession(session.id);
    if (generation != _generation) return;

    switch (result) {
      case Ok<RemoteSession>(:final value):
        // The backend returned the CLOSED session, so the screen can leave the
        // assistance at once...
        emit(_stateFor(value));
        // ...and the contract's own recovery call confirms it. Normally `null`.
        await _sync(emit);
      case Err<RemoteSession>(:final failure):
        if (_meansStaleState(failure)) {
          // `404`/`409`: the session was already gone, or its request is no
          // longer completable — the technician closed first, most likely.
          // Nothing is guessed; the backend is asked.
          await _sync(emit, reason: failure);
          return;
        }
        // Nothing is known to have happened at the backend, so the session
        // stays exactly as it was and the user may try again.
        emit(_stateFor(session, lastFailure: failure));
    }
  }

  // ------------------------------------------------------------------- reset

  Future<void> _onResetRequested(
    RemoteSessionResetRequested event,
    Emitter<RemoteSessionState> emit,
  ) async {
    _generation++;
    emit(const RemoteSessionInitial());
  }

  // ---------------------------------------------------------------- plumbing

  bool get _closeInFlight => switch (state) {
    RemoteSessionLive(:final closing) => closing,
    _ => false,
  };

  /// `404` and `409` both mean the same thing here: what this client believed
  /// is no longer what the backend holds. The contract is explicit that the
  /// client re-reads state rather than interpreting the message.
  static bool _meansStaleState(Failure failure) =>
      failure is ConflictFailure || failure is NotFoundFailure;

  /// The single mapping from a backend payload to a screen state.
  static RemoteSessionState _stateFor(
    RemoteSession? session, {
    bool closing = false,
    Failure? lastFailure,
  }) {
    if (session == null) return RemoteSessionIdle(lastFailure: lastFailure);

    return switch (session.status) {
      RemoteSessionStatus.connecting => RemoteSessionConnecting(
        session,
        closing: closing,
        lastFailure: lastFailure,
      ),
      RemoteSessionStatus.active => RemoteSessionActive(
        session,
        closing: closing,
        lastFailure: lastFailure,
      ),
      // `CLOSED` is terminal and `/current` never returns it; it reaches here
      // only as the answer to this device's own close. `unknown` lands here
      // too — a status this build cannot interpret must not be rendered as if
      // it were one it can, and above all must not claim that a technician is
      // connected.
      RemoteSessionStatus.closed ||
      RemoteSessionStatus.unknown => RemoteSessionIdle(
        lastFailure: lastFailure,
      ),
    };
  }

  void _log(String message) {
    if (kDebugMode) developer.log(message, name: _loggerName);
  }
}
