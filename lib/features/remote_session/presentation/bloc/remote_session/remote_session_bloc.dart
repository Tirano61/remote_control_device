import 'dart:developer' as developer;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_device/features/remote_session/domain/storage/ended_remote_session_store.dart';
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
///
/// The third rule is the one exception to "the backend decides", and it only
/// ever points one way: **the user of this tablet can end the assistance here
/// without asking anyone.** `FINALIZAR ASISTENCIA` moves the session to
/// [RemoteSessionEndedLocally] before anything is sent, and from then on the
/// backend can confirm that end but never undo it:
///
/// ```text
/// FINALIZAR                 ──> ended here, at once, for good
///   POST close  200 CLOSED  ──> confirmed: Idle
///   POST close  404 / 409   ──> /current decides whether it is confirmed
///   POST close  anything else (network, 5xx, 401, 400)
///                           ──> still ended here; confirmation pending
///
/// a later /current returning that same session live
///                           ──> still ended here, and the close is sent again
/// a later /current returning nothing, or another session
///                           ──> confirmed
/// ```
///
/// The ended session is remembered in memory for the life of the bloc and in
/// an [EndedRemoteSessionStore] until the backend confirms it, so neither a
/// late answer nor a restart of the application can hand it back as live.
class RemoteSessionBloc extends Bloc<RemoteSessionEvent, RemoteSessionState> {
  RemoteSessionBloc({
    required LoadCurrentRemoteSession loadCurrentRemoteSession,
    required CloseRemoteSession closeRemoteSession,
    required EndedRemoteSessionStore endedSessionStore,
  }) : _loadCurrentRemoteSession = loadCurrentRemoteSession,
       _closeRemoteSession = closeRemoteSession,
       _endedSessionStore = endedSessionStore,
       super(const RemoteSessionInitial()) {
    on<RemoteSessionSyncRequested>(_onSyncRequested);
    on<RemoteSessionAnnounced>(_onAnnounced);
    on<RemoteSessionActivationAnnounced>(_onActivationAnnounced);
    on<RemoteSessionClosureAnnounced>(_onClosureAnnounced);
    on<RemoteSessionCloseRequested>(_onCloseRequested);
    on<RemoteSessionResetRequested>(_onResetRequested);
  }

  static const String _loggerName = 'remote-session';

  final LoadCurrentRemoteSession _loadCurrentRemoteSession;
  final CloseRemoteSession _closeRemoteSession;
  final EndedRemoteSessionStore _endedSessionStore;

  /// Bumped when the device identity is dropped. An answer that arrives after
  /// that belongs to a device this installation no longer is, so it is
  /// discarded instead of being written over the cleared state.
  int _generation = 0;

  /// Every session the user ended on this tablet while this bloc lived, plus
  /// the one recovered from [_endedSessionStore]. Only ever added to: this is
  /// what makes ending an assistance monotonic. A session in here is never
  /// mapped to a live state again, whatever the backend answers about it.
  final Set<String> _endedHere = <String>{};

  /// The session [_endedSessionStore] holds, as far as this bloc knows: ended
  /// here and not yet confirmed `CLOSED` by the backend.
  String? _pendingConfirmation;

  /// The one read of [_endedSessionStore] per application run. Every path that
  /// maps a backend answer waits for it first, so a session ended before a
  /// restart is already known when `/current` first returns it.
  Future<void>? _markerLoaded;

  /// The close currently on its way to the backend, if any. An identity token
  /// rather than a flag, so a close abandoned by a reset cannot clear the flag
  /// of one started after it.
  Object? _confirming;

  // ----------------------------------------------------------------- syncing

  Future<void> _onSyncRequested(
    RemoteSessionSyncRequested event,
    Emitter<RemoteSessionState> emit,
  ) async {
    // A close already in flight will settle the state with the backend's own
    // answer; a sync racing it could only overwrite that with an older read.
    if (_confirmInFlight) return;
    await _syncAndReconcile(emit);
  }

  Future<void> _onAnnounced(
    RemoteSessionAnnounced event,
    Emitter<RemoteSessionState> emit,
  ) async {
    if (_confirmInFlight) return;

    final known = state;
    if (known is RemoteSessionLive &&
        known.session.id != event.remoteSessionId) {
      // Not a reason to distrust the answer that follows — the backend is asked
      // either way — but worth knowing: the local copy was already stale.
      _log('a session was announced other than the one held');
    }
    await _syncAndReconcile(emit);
  }

  /// `remote-session:active`: the only cue this bloc filters before reading.
  ///
  /// ```text
  /// it names the live session held      ──> read /current, and that decides
  /// the session held is already ACTIVE  ──> ignored: nothing left to learn
  /// it names another session            ──> ignored: ownership never moves
  ///                                          because of a realtime payload
  /// it names the session ended here     ──> ignored: an ended assistance is
  ///                                          not resumed by any event
  /// no session is held yet              ──> read /current
  /// ```
  ///
  /// The third line is the isolation rule. The last is not a hole in it:
  /// reading `/current` can only ever produce *this* device's session, because
  /// the backend answers it from the Device JWT and not from anything the event
  /// said. It covers the one case where the id cannot be matched yet — a read
  /// that failed, or one that has not happened — and it is how a device whose
  /// first sync came back empty still reaches `ACTIVE`.
  ///
  /// The second line is what keeps this from looping. The read this event
  /// triggers ends in `ACTIVE`, and a state that is already `ACTIVE` triggers
  /// no further read, so the chain is at most one call long.
  Future<void> _onActivationAnnounced(
    RemoteSessionActivationAnnounced event,
    Emitter<RemoteSessionState> emit,
  ) async {
    if (_confirmInFlight) return;

    final known = state;
    if (known is RemoteSessionLive) {
      if (known.session.id != event.remoteSessionId) {
        // An activation is, by definition, about a session that already
        // exists — so unlike a creation or a closure it cannot be news about
        // the one on screen, and the session on screen is the one an
        // authenticated read produced. It is dropped without a call: the
        // session held keeps its identity, and the cues that do reconcile a
        // stale one — a reconnection, a refused join, a closure — are
        // unaffected.
        _log(
          'an activation was announced for a session other than the one '
          'held: ignored',
        );
        return;
      }
      if (known is RemoteSessionActive) {
        _log('an activation was announced for a session already ACTIVE');
        return;
      }
    }
    if (_endedHere.contains(event.remoteSessionId)) {
      // The technician's `/activate` committed before the close did, or the
      // event was simply late. Either way it is about an assistance the user
      // already ended, and it is not a reason to look at it again.
      _log(
        'an activation was announced for a session ended on this tablet: '
        'ignored',
      );
      return;
    }

    await _syncAndReconcile(emit);
  }

  Future<void> _onClosureAnnounced(
    RemoteSessionClosureAnnounced event,
    Emitter<RemoteSessionState> emit,
  ) async {
    if (_confirmInFlight) return;

    final known = state;
    if (known is RemoteSessionLive &&
        known.session.id != event.remoteSessionId) {
      _log('a closure was announced for a session other than the one held');
    }
    // Deliberately the same handler as every other cue. The event says a
    // session ended; only the empty answer to this read ends it here.
    await _syncAndReconcile(emit);
  }

  /// A read, and — when it shows the backend still holds live a session the
  /// user ended here — one more close of it.
  ///
  /// This is the whole reconciliation of an unconfirmed end, and it is
  /// deliberately borrowed rather than scheduled: it runs on the cues that
  /// already cause a read (the socket coming back, the application starting,
  /// a realtime event, REINTENTAR), at most one close per cue, and only when
  /// the read itself reached the backend. There is no timer and no retry loop:
  /// a tablet that cannot reach the server stays ended and keeps waiting.
  Future<void> _syncAndReconcile(Emitter<RemoteSessionState> emit) async {
    final answered = await _sync(emit);
    if (!answered || _confirmInFlight) return;

    final current = state;
    if (current is RemoteSessionEndedLocally) {
      _log(
        'session ${current.remoteSessionId} ended here is still live at '
        'the backend: closing it again',
      );
      await _confirm(emit, current.remoteSessionId);
    }
  }

  /// Reads `/current` and adopts whatever it says — except that a session
  /// ended on this tablet is never adopted as live. Returns whether the
  /// backend answered.
  ///
  /// A known state never becomes *unknown* because the call failed. A live
  /// session stays live — a tablet that lost Wi-Fi must not tell the user the
  /// assistance is over — and a confirmed "no session" stays that way. An
  /// assistance ended here stays ended. Only a backend answer moves any of
  /// them.
  ///
  /// Callers that are themselves an operation — a close, or one that came back
  /// `404`/`409` — reach this directly: re-reading is the whole point of those
  /// paths, which is why the in-flight guard lives in the event handlers above
  /// rather than here.
  Future<bool> _sync(
    Emitter<RemoteSessionState> emit, {
    Failure? reason,
  }) async {
    final generation = _generation;
    final known = state;
    if (known is RemoteSessionInitial || known is RemoteSessionUnavailable) {
      emit(const RemoteSessionLoading());
    }

    await _loadMarker();
    if (generation != _generation) return false;

    final result = await _loadCurrentRemoteSession();
    if (generation != _generation) return false;

    switch (result) {
      case Ok<RemoteSession?>(:final value):
        await _settleConfirmation(value);
        if (generation != _generation) return false;
        emit(_stateFor(value, lastFailure: reason));
        return true;
      case Err<RemoteSession?>(:final failure):
        // Read *now*, not before the call: a FINALIZAR pressed while this read
        // was in flight has already moved the state, and that is what stands.
        emit(switch (state) {
          RemoteSessionLive(:final session) => _stateFor(
            session,
            lastFailure: reason,
          ),
          RemoteSessionEndedLocally(:final remoteSessionId) => _endedState(
            remoteSessionId,
            lastFailure: reason ?? failure,
          ),
          // "There is no session" was established by the backend once; a
          // re-read that could not reach it does not un-establish it.
          RemoteSessionIdle() => RemoteSessionIdle(lastFailure: reason),
          _ => RemoteSessionUnavailable(reason ?? failure),
        });
        return false;
    }
  }

  // ----------------------------------------------------------------- closing

  Future<void> _onCloseRequested(
    RemoteSessionCloseRequested event,
    Emitter<RemoteSessionState> emit,
  ) async {
    switch (state) {
      case RemoteSessionLive(:final session):
        await _endHere(emit, session.id);
      case RemoteSessionEndedLocally(:final remoteSessionId)
          when !_confirmInFlight:
        // REINTENTAR: the assistance is already over here; this only tells the
        // backend again.
        await _confirm(emit, remoteSessionId);
      default:
        // Nothing to close, or a close already under way. This is the whole
        // double-tap protection: the state leaves the live family before
        // anything is awaited, so a second press finds nothing to end.
        return;
    }
  }

  /// Ends the assistance on this tablet, then tells the backend.
  ///
  /// Everything that withdraws the technician's access happens in the first,
  /// synchronous part: the session joins [_endedHere] and the state becomes
  /// [RemoteSessionEndedLocally]. Every coordinator reads that as "no
  /// assistance", so the control channel stops obeying, a remote touch is let
  /// go, the peer connection closes and the screen capture stops — none of it
  /// waiting for the network, and none of it undone by what the network says.
  ///
  /// The id comes from the state, which was built from an authenticated
  /// response — never from the widget that raised the event, and never from a
  /// realtime payload. The backend still checks ownership; this only makes sure
  /// the client never invents an id to act on.
  Future<void> _endHere(
    Emitter<RemoteSessionState> emit,
    String remoteSessionId,
  ) async {
    final generation = _generation;
    _endedHere.add(remoteSessionId);
    final token = _confirming = Object();
    emit(_endedState(remoteSessionId));
    _log('assistance ended on this tablet for $remoteSessionId');

    // Remembered before the backend is told, so that an application killed
    // while the close is in flight still refuses this session when it starts
    // again. The marker never gates the end itself: a store that cannot be
    // written costs the restart guarantee, not the local revocation.
    await _loadMarker();
    await _rememberPending(remoteSessionId);
    if (generation != _generation) {
      if (identical(_confirming, token)) _confirming = null;
      return;
    }

    await _confirm(emit, remoteSessionId, token: token);
  }

  /// Sends the close for a session already ended here, and records what the
  /// backend made of it. Never moves the session back to live.
  Future<void> _confirm(
    Emitter<RemoteSessionState> emit,
    String remoteSessionId, {
    Object? token,
  }) async {
    final generation = _generation;
    final confirming = _confirming = token ?? Object();
    emit(_endedState(remoteSessionId));

    void done() {
      if (identical(_confirming, confirming)) _confirming = null;
    }

    try {
      final result = await _closeRemoteSession(remoteSessionId);
      if (generation != _generation) return;

      switch (result) {
        case Ok<RemoteSession>(:final value):
          // The backend returned the CLOSED session: confirmed. The screen can
          // leave the assistance at once...
          if (value.status == RemoteSessionStatus.closed) {
            _log('close of $remoteSessionId confirmed by the backend');
            await _forgetPending(remoteSessionId);
            if (generation != _generation) return;
          }
          done();
          emit(_stateFor(value));
          // ...and the contract's own recovery call agrees. Normally `null`.
          await _sync(emit);
        case Err<RemoteSession>(:final failure) when _meansStaleState(failure):
          // `404`/`409`: the session was already gone, or its request is no
          // longer completable — the technician closed first, most likely.
          // Nothing is guessed; the backend is asked, and whatever it answers
          // this session stays ended here.
          done();
          await _sync(emit, reason: failure);
        case Err<RemoteSession>(:final failure):
          // Network, 5xx, 401, 400: nothing is known to have happened at the
          // backend. The assistance is still over on this tablet — that was
          // never the backend's to decide — and only the confirmation is
          // pending. The next reconnection, the next start of the application
          // or REINTENTAR sends it again.
          _log(
            'close of $remoteSessionId not confirmed by the backend: '
            '${failure.runtimeType}',
          );
          done();
          emit(_endedState(remoteSessionId, lastFailure: failure));
      }
    } finally {
      done();
    }
  }

  // ------------------------------------------------------------------- reset

  Future<void> _onResetRequested(
    RemoteSessionResetRequested event,
    Emitter<RemoteSessionState> emit,
  ) async {
    _generation++;
    _confirming = null;
    // [_endedHere] and the stored marker are deliberately kept. A session the
    // user ended does not become acceptable because the identity was reset: a
    // device enrolled again may still find it live at the backend, and it is
    // still refused.
    emit(const RemoteSessionInitial());
  }

  // ---------------------------------------------------------------- marker

  Future<void> _loadMarker() => _markerLoaded ??= _readMarker();

  Future<void> _readMarker() async {
    try {
      final remoteSessionId = await _endedSessionStore.read();
      if (remoteSessionId == null) return;
      _endedHere.add(remoteSessionId);
      _pendingConfirmation ??= remoteSessionId;
      _log(
        'session $remoteSessionId was ended on this tablet before: '
        'it will not be resumed',
      );
    } on EndedRemoteSessionStoreException {
      _log('the ended-session marker could not be read');
    }
  }

  Future<void> _rememberPending(String remoteSessionId) async {
    _pendingConfirmation = remoteSessionId;
    try {
      await _endedSessionStore.write(remoteSessionId);
    } on EndedRemoteSessionStoreException {
      _log('the ended-session marker could not be written');
    }
  }

  Future<void> _forgetPending(String remoteSessionId) async {
    if (_pendingConfirmation != remoteSessionId) return;
    _pendingConfirmation = null;
    try {
      await _endedSessionStore.clear();
    } on EndedRemoteSessionStoreException {
      // Harmless: a stale marker only names a session the backend no longer
      // holds live, and the next read that shows that clears it again.
      _log('the ended-session marker could not be cleared');
    }
  }

  /// A `/current` answer is the other way an end gets confirmed: if the session
  /// ended here is not what the backend returns as live, the backend no longer
  /// holds it live for this device. A device has at most one live session, so
  /// another one being returned says the same thing.
  Future<void> _settleConfirmation(RemoteSession? live) async {
    final pending = _pendingConfirmation;
    if (pending == null) return;
    if (live != null && live.id == pending && _isLiveStatus(live.status)) {
      return;
    }
    _log('session $pending ended here is no longer live: confirmed');
    await _forgetPending(pending);
  }

  // ---------------------------------------------------------------- plumbing

  bool get _confirmInFlight => _confirming != null;

  /// `404` and `409` both mean the same thing here: what this client believed
  /// is no longer what the backend holds. The contract is explicit that the
  /// client re-reads state rather than interpreting the message.
  static bool _meansStaleState(Failure failure) =>
      failure is ConflictFailure || failure is NotFoundFailure;

  static bool _isLiveStatus(RemoteSessionStatus status) =>
      status == RemoteSessionStatus.connecting ||
      status == RemoteSessionStatus.active;

  RemoteSessionEndedLocally _endedState(
    String remoteSessionId, {
    Failure? lastFailure,
  }) => RemoteSessionEndedLocally(
    remoteSessionId,
    confirming: _confirmInFlight,
    lastFailure: lastFailure,
  );

  /// The single mapping from a backend payload to a screen state.
  RemoteSessionState _stateFor(RemoteSession? session, {Failure? lastFailure}) {
    if (session == null) return RemoteSessionIdle(lastFailure: lastFailure);

    // The one place a backend answer is overruled, and only in one direction:
    // a session the user ended here is reported as ended, never as live.
    if (_endedHere.contains(session.id) && _isLiveStatus(session.status)) {
      return _endedState(session.id, lastFailure: lastFailure);
    }

    return switch (session.status) {
      RemoteSessionStatus.connecting => RemoteSessionConnecting(
        session,
        lastFailure: lastFailure,
      ),
      RemoteSessionStatus.active => RemoteSessionActive(
        session,
        lastFailure: lastFailure,
      ),
      // `CLOSED` is terminal and `/current` never returns it; it reaches here
      // only as the answer to this device's own close. `unknown` lands here
      // too — a status this build cannot interpret must not be rendered as if
      // it were one it can, and above all must not claim that a technician is
      // connected.
      RemoteSessionStatus.closed || RemoteSessionStatus.unknown =>
        RemoteSessionIdle(lastFailure: lastFailure),
    };
  }

  void _log(String message) {
    if (kDebugMode) developer.log(message, name: _loggerName);
  }
}
