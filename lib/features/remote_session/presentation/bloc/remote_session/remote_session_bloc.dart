import 'dart:async';
import 'dart:developer' as developer;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/core/async/timer_factory.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_ended_by.dart';
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
/// by itself — it produces a `GET /device/remote-sessions/current`, and *that*
/// answer decides. The price is one extra call per event; what it buys is that
/// a tablet which was asleep, offline, or simply restarted ends up in the same
/// state as one that received every event, because the recovery path and the
/// happy path are the same code.
///
/// The second rule is that nothing is ever *invented*. A call that fails
/// because the network is down leaves a live session exactly where it was: the
/// user is told the connection is being retried, never that the technician
/// hung up.
///
/// The third rule is the exception to "the backend decides", and it only ever
/// points one way: **anything that withdraws the technician's access may act
/// before REST answers; nothing that grants it may.** Three things withdraw it:
///
/// ```text
/// FINALIZAR here             ──> RemoteSessionEndedLocally, at once, for good
///   POST close  200, this id, CLOSED, endedAt
///                            ──> confirmed: Idle, whoever closed it first
///                                (the close is idempotent: endedBy may be
///                                DEVICE, TECHNICIAN or SYSTEM)
///   POST close  200 that says anything else (another id, a live status,
///               no endedAt)  ──> not a confirmation; /current decides
///   POST close  404 / 409    ──> /current decides whether it is confirmed
///   POST close  anything else (network, timeout, 5xx, 401, 400)
///                            ──> still ended here; confirmation pending
///
/// remote-session:closed for the session held (TECHNICIAN or SYSTEM)
///                            ──> RemoteSessionClosedRemotely, at once, for
///                                good; then /current
///
/// the realtime channel lost  ──> the session stays live but SUSPENDED: no
///                                command runs. `/current` is re-read with
///                                backoff ([defaultAuthorityRetryBackoff]); an
///                                answer without this session live ends it at
///                                once. Peer and screen are kept for at most
///                                [authorityGracePeriod]; if the session is not
///                                confirmed again by then, it is ended here —
///                                torn down exactly as FINALIZAR would, but
///                                *without* a close: the backend closes it on
///                                its own (SYSTEM).
/// ```
///
/// And one thing grants it back: a `/current` read that *started after* the
/// realtime channel last came up, answering the same session `ACTIVE`. A read
/// that started earlier, one that failed, or one that answers while the channel
/// is down again confirms nothing — see [_authorityEpoch].
///
/// Sessions ended here or closed by the backend are remembered (in memory, and
/// the former also in an [EndedRemoteSessionStore] until the backend confirms
/// it), so neither a late answer, an event nor a restart of the application
/// can hand them back as live.
class RemoteSessionBloc extends Bloc<RemoteSessionEvent, RemoteSessionState> {
  RemoteSessionBloc({
    required LoadCurrentRemoteSession loadCurrentRemoteSession,
    required CloseRemoteSession closeRemoteSession,
    required EndedRemoteSessionStore endedSessionStore,
    Duration authorityGracePeriod = defaultAuthorityGracePeriod,
    List<Duration> authorityRetryBackoff = defaultAuthorityRetryBackoff,
    TimerFactory timerFactory = systemTimerFactory,
  }) : _loadCurrentRemoteSession = loadCurrentRemoteSession,
       _closeRemoteSession = closeRemoteSession,
       _endedSessionStore = endedSessionStore,
       _authorityGracePeriod = authorityGracePeriod,
       _authorityRetryBackoff = List.unmodifiable(authorityRetryBackoff),
       _timerFactory = timerFactory,
       super(const RemoteSessionInitial()) {
    on<RemoteSessionSyncRequested>(_onSyncRequested);
    on<RemoteSessionAnnounced>(_onAnnounced);
    on<RemoteSessionActivationAnnounced>(_onActivationAnnounced);
    on<RemoteSessionClosureAnnounced>(_onClosureAnnounced);
    on<RemoteSessionCloseRequested>(_onCloseRequested);
    on<RemoteSessionResetRequested>(_onResetRequested);
    on<RemoteSessionAuthorityChannelChanged>(_onAuthorityChannelChanged);
    on<_RemoteSessionAuthorityGraceExpired>(_onAuthorityGraceExpired);
    on<_RemoteSessionAuthorityRetryDue>(_onAuthorityRetryDue);
  }

  /// The backend's own grace for a side that left an `ACTIVE` session
  /// (`REMOTE_SESSION_DISCONNECT_GRACE_MS`, 60 s by default in REALTIME.md).
  /// Counted by the backend from the moment *it* sees this device's last
  /// joined socket go; if the device has not joined again by then, the backend
  /// closes the session with `SYSTEM`.
  static const Duration backendDisconnectGrace = Duration(seconds: 60);

  /// How long a live session may stay [RemoteSessionAuthority.suspended]
  /// before the tablet ends it by itself: [backendDisconnectGrace] + 15 s.
  ///
  /// Counted from the moment *this tablet* noticed it could no longer confirm
  /// the session — not from when the backend noticed, which may be earlier or
  /// later (up to a ping timeout, ~45 s with Socket.IO defaults). The two
  /// clocks are never compared.
  ///
  /// It is a backstop, not the normal way a lost session ends:
  ///
  /// * control is suspended for the whole window, from its first instant,
  ///   whatever the window is. The window only bounds how long the *screen*
  ///   may keep flowing to a peer the tablet cannot vouch for;
  /// * while the backend can be reached, it decides: a suspended session is
  ///   re-read with backoff, and the `SYSTEM` close the backend makes 60 s
  ///   after noticing is seen by the next read, at most one backoff step
  ///   later;
  /// * not shorter than [backendDisconnectGrace]: a tablet that noticed the
  ///   loss together with the backend must not give up on a session the
  ///   backend would still let it rejoin. The old 45 s did (M1, Prompt 38);
  /// * the 15 s over it cover the backend noticing a clean drop slightly
  ///   later than the tablet, plus one backoff step (8 s) and the round trip
  ///   of the read that sees the `SYSTEM` close — so when the backend is
  ///   reachable, the backend's close, not this timer, ends the session;
  /// * it is not restarted by a socket that flaps, by a reconnection whose
  ///   read fails, or by a read answering `ACTIVE` while the socket is down.
  static const Duration defaultAuthorityGracePeriod = Duration(seconds: 75);

  /// Delays between re-reads of `/current` while a session is suspended. The
  /// last one repeats. Restarted whenever the realtime channel changes, so
  /// the read after a reconnection is retried promptly if it fails.
  ///
  /// Before Prompt 38 nothing retried: one failed read after a reconnection
  /// left the session suspended — with the socket up and REST working again —
  /// until the grace period ended it (M1).
  static const List<Duration> defaultAuthorityRetryBackoff = [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];

  static const String _loggerName = 'remote-session';

  final LoadCurrentRemoteSession _loadCurrentRemoteSession;
  final CloseRemoteSession _closeRemoteSession;
  final EndedRemoteSessionStore _endedSessionStore;
  final Duration _authorityGracePeriod;
  final List<Duration> _authorityRetryBackoff;
  final TimerFactory _timerFactory;

  /// Bumped when the device identity is dropped. An answer that arrives after
  /// that belongs to a device this installation no longer is, so it is
  /// discarded instead of being written over the cleared state.
  int _generation = 0;

  /// Every session the user ended on this tablet while this bloc lived, plus
  /// the one recovered from [_endedSessionStore]. Only ever added to: this is
  /// what makes ending an assistance monotonic. A session in here is never
  /// mapped to a live state again, whatever the backend answers about it.
  final Set<String> _endedHere = <String>{};

  /// Why each session in [_endedHere] was ended here, when this run knows.
  final Map<String, RemoteSessionLocalEndReason> _endReasons = {};

  /// Every session `remote-session:closed` named, with who closed it. `CLOSED`
  /// is terminal at the backend, so an id in here can never legitimately be
  /// live again: a read answering otherwise is a read that was overtaken.
  final Map<String, RemoteSessionEndedBy> _closedRemotely = {};

  /// Who closed the session this tablet was last taking part in, when it was
  /// closed from the other side. Shown by [RemoteSessionIdle]; cleared when
  /// another session begins or the user ends one here.
  RemoteSessionEndedBy? _lastClosure;

  /// Whether the session this tablet was last taking part in ended while its
  /// authority was suspended, with nobody saying who closed it. Shown through
  /// [RemoteSessionIdle.interrupted].
  bool _interrupted = false;

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

  /// Whether the realtime channel — the backend's only way to tell this tablet
  /// that a session was closed — is up. `false` until told otherwise: a live
  /// session read before the channel exists is not confirmed.
  bool _authorityChannelUp = false;

  /// Moves whenever what a read could confirm changes: the channel going down,
  /// the channel coming up, a closure, a reset. A read remembers the value it
  /// started with, and only a read whose value is still current, with the
  /// channel up, confirms a session. So a `GET /current` that was already in
  /// flight when the socket dropped (or when it came back) cannot restore
  /// control with an answer the backend gave before.
  int _authorityEpoch = 0;

  /// The grace period running for a suspended session, if any.
  Timer? _graceTimer;
  String? _graceSessionId;

  /// The next re-read of a suspended session, if one is scheduled, and how
  /// many have been made since the channel last changed.
  Timer? _retryTimer;
  int _retryAttempt = 0;

  /// `/current` reads on the wire. A retry is never stacked on one: the read
  /// in flight schedules the next retry when it answers.
  int _readsInFlight = 0;

  // ------------------------------------------------------------- authority

  /// The realtime channel came up or went down.
  ///
  /// Going down suspends a live session at once, before anything is awaited:
  /// whatever the technician sends from now on is refused, a remote touch is
  /// let go, and queued commands are dropped. Coming up confirms nothing by
  /// itself; the read that follows it does.
  void _onAuthorityChannelChanged(
    RemoteSessionAuthorityChannelChanged event,
    Emitter<RemoteSessionState> emit,
  ) {
    if (event.available == _authorityChannelUp) return;
    _authorityChannelUp = event.available;
    _authorityEpoch++;
    // A new channel state is a new situation: back to the shortest delay, so
    // the read that follows a reconnection is retried promptly if it fails.
    _cancelRetry();
    _retryAttempt = 0;

    final current = state;
    if (current is RemoteSessionLive && !current.isSuspended) {
      _log(
        'authority over ${current.session.id} suspended: the realtime '
        'channel is ${event.available ? 'back but not reconciled' : 'down'}',
      );
      emit(_withAuthority(current, RemoteSessionAuthority.suspended));
    }
    _ensureRetry(state);
  }

  /// A scheduled re-read of a suspended session.
  ///
  /// It confirms under the same rule as any other read — the channel up and
  /// the read started after it came up — and ends the session the way any
  /// other read does: by the backend no longer returning it live. With the
  /// channel down it confirms nothing, but it still finds a session the
  /// backend closed (`SYSTEM`, or the technician) while the
  /// `remote-session:closed` event could not reach this tablet.
  Future<void> _onAuthorityRetryDue(
    _RemoteSessionAuthorityRetryDue event,
    Emitter<RemoteSessionState> emit,
  ) async {
    final current = state;
    if (current is! RemoteSessionLive || !current.isSuspended) return;
    // A read already on the wire answers the same question, and schedules
    // the next retry itself when it does.
    if (_readsInFlight > 0 || _confirmInFlight) return;
    _retryAttempt++;
    _log(
      'authority over ${current.session.id} still suspended: re-reading '
      '(attempt $_retryAttempt)',
    );
    await _syncAndReconcile(emit);
  }

  /// The grace period of a suspended session ran out.
  ///
  /// The session is ended here and torn down through the same path as
  /// FINALIZAR: it joins the ended set and the persistent marker is written.
  /// An assistance whose authorisation could not be confirmed for this long is
  /// not resumed, and a new one needs a new request and a new consent.
  ///
  /// What it does *not* do is send `POST /device/remote-sessions/:id/close`.
  /// That call is recorded as `endedBy: DEVICE` — the user pressed FINALIZAR —
  /// and the user did not. The device no longer takes part in the session (it
  /// joins the signaling room only of a session it has confirmed), so the
  /// backend closes it on its own with `SYSTEM`, which is what happened. See
  /// [_syncAndReconcile].
  Future<void> _onAuthorityGraceExpired(
    _RemoteSessionAuthorityGraceExpired event,
    Emitter<RemoteSessionState> emit,
  ) async {
    final current = state;
    if (current is! RemoteSessionLive ||
        current.session.id != event.remoteSessionId ||
        !current.isSuspended) {
      return;
    }
    _log(
      'authority over ${current.session.id} not confirmed within '
      '${_authorityGracePeriod.inSeconds} s: ending it on this tablet '
      '(no close sent: the backend closes it as SYSTEM)',
    );
    await _endHere(
      emit,
      current.session.id,
      reason: RemoteSessionLocalEndReason.authorityLost,
    );
  }

  /// Starts, keeps or cancels the grace period and the re-reads after every
  /// state change.
  ///
  /// The grace period runs from the first moment a live session is suspended
  /// and is *not* restarted by later suspended states of the same session — a
  /// reconnection whose read fails, a socket that flaps, or a read answering
  /// `ACTIVE` while the channel is down does not buy more time.
  @override
  void onChange(Change<RemoteSessionState> change) {
    super.onChange(change);
    final next = change.nextState;
    if (next is RemoteSessionLive && next.isSuspended) {
      final id = next.session.id;
      if (_graceTimer == null || _graceSessionId != id) {
        _cancelGrace();
        _graceSessionId = id;
        _graceTimer = _timerFactory(_authorityGracePeriod, () {
          _graceTimer = null;
          if (!isClosed) add(_RemoteSessionAuthorityGraceExpired(id));
        });
      }
      // `state` is still the previous one while onChange runs.
      _ensureRetry(next);
    } else {
      _cancelGrace();
      _cancelRetry();
      _retryAttempt = 0;
    }
  }

  void _cancelGrace() {
    _graceTimer?.cancel();
    _graceTimer = null;
    _graceSessionId = null;
  }

  /// Schedules the next re-read if [current] is a suspended live session and
  /// neither a re-read nor a read is already pending.
  void _ensureRetry(RemoteSessionState current) {
    if (isClosed) return;
    if (current is! RemoteSessionLive || !current.isSuspended) {
      _cancelRetry();
      return;
    }
    if (_retryTimer != null || _readsInFlight > 0) return;
    if (_authorityRetryBackoff.isEmpty) return;
    final step = _retryAttempt < _authorityRetryBackoff.length
        ? _retryAttempt
        : _authorityRetryBackoff.length - 1;
    _retryTimer = _timerFactory(_authorityRetryBackoff[step], () {
      _retryTimer = null;
      if (!isClosed) add(const _RemoteSessionAuthorityRetryDue());
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// What a read that started at [epoch] may say about authority.
  RemoteSessionAuthority _authorityFor(int epoch) =>
      _authorityChannelUp && epoch == _authorityEpoch
      ? RemoteSessionAuthority.confirmed
      : RemoteSessionAuthority.suspended;

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
  /// the session held is already ACTIVE
  ///   and confirmed                     ──> ignored: nothing left to learn
  /// it names another session            ──> ignored: ownership never moves
  ///                                          because of a realtime payload
  /// it names a session ended here, or
  ///   one the backend said was closed   ──> ignored: an ended assistance is
  ///                                          not resumed by any event
  /// no session is held yet              ──> read /current
  /// ```
  ///
  /// The third line is the isolation rule. The last is not a hole in it:
  /// reading `/current` can only ever produce *this* device's session, because
  /// the backend answers it from the Device JWT and not from anything the event
  /// said.
  ///
  /// The second line is what keeps this from looping. The read this event
  /// triggers ends in `ACTIVE`, and a confirmed `ACTIVE` triggers no further
  /// read, so the chain is at most one call long.
  Future<void> _onActivationAnnounced(
    RemoteSessionActivationAnnounced event,
    Emitter<RemoteSessionState> emit,
  ) async {
    if (_confirmInFlight) return;

    final known = state;
    if (known is RemoteSessionLive) {
      if (known.session.id != event.remoteSessionId) {
        _log(
          'an activation was announced for a session other than the one '
          'held: ignored',
        );
        return;
      }
      if (known is RemoteSessionActive && !known.isSuspended) {
        _log('an activation was announced for a session already ACTIVE');
        return;
      }
    }
    if (_endedHere.contains(event.remoteSessionId) ||
        _closedRemotely.containsKey(event.remoteSessionId)) {
      _log('an activation was announced for a session that is over: ignored');
      return;
    }

    await _syncAndReconcile(emit);
  }

  /// `remote-session:closed`.
  ///
  /// For the session held, control is withdrawn before anything is awaited:
  /// the state leaves the live family on the spot, so the coordinators take
  /// down control, the peer connection, the signaling room and the screen
  /// capture in the same order FINALIZAR does. `CLOSED` is terminal at the
  /// backend, so acting on the event can only be early, never wrong — and a
  /// forged or stale one could at worst end an assistance, never grant one.
  ///
  /// The id is recorded whatever is held, for the same reason: a read already
  /// in flight that answers with that session live was overtaken by the close,
  /// and is mapped to closed.
  ///
  /// `/current` is read afterwards as with every other cue, and decides what
  /// comes next: normally nothing (Idle), possibly a new session.
  Future<void> _onClosureAnnounced(
    RemoteSessionClosureAnnounced event,
    Emitter<RemoteSessionState> emit,
  ) async {
    final id = event.remoteSessionId;
    _closedRemotely.putIfAbsent(id, () => event.endedBy);

    final known = state;
    if (known is RemoteSessionLive) {
      if (known.session.id == id) {
        _authorityEpoch++;
        _lastClosure = event.endedBy;
        _log(
          'session $id closed by the backend (${event.endedBy.name}): '
          'control withdrawn',
        );
        emit(RemoteSessionClosedRemotely(id, endedBy: event.endedBy));
      } else {
        _log('a closure was announced for a session other than the one held');
      }
    }

    if (_confirmInFlight) return;
    await _syncAndReconcile(emit);
  }

  /// A read, and — when it shows the backend still holds live a session the
  /// user ended here with FINALIZAR — one more close of it.
  ///
  /// A session the tablet stopped because it lost authority gets no close,
  /// here or anywhere: the device does not take part in it any more, so the
  /// backend's grace runs out and it closes the session with `SYSTEM`. Until
  /// then the session simply stays ended here.
  ///
  /// This is the whole reconciliation of an unconfirmed end, and it is
  /// deliberately borrowed rather than scheduled: it runs on the cues that
  /// already cause a read (the socket coming back, the application starting,
  /// a realtime event, REINTENTAR), at most one close per cue, and only when
  /// the read itself reached the backend.
  Future<void> _syncAndReconcile(Emitter<RemoteSessionState> emit) async {
    final answered = await _sync(emit);
    if (!answered || _confirmInFlight) return;

    final current = state;
    if (current is RemoteSessionEndedLocally) {
      if (!_closeOwed(current.remoteSessionId)) {
        _log(
          'session ${current.remoteSessionId} stopped here (authority lost) '
          'is still live at the backend: waiting for its own close',
        );
        return;
      }
      _log(
        'session ${current.remoteSessionId} ended here is still live at '
        'the backend: closing it again',
      );
      await _confirm(emit, current.remoteSessionId);
    }
  }

  /// Reads `/current` and adopts whatever it says — except that a session
  /// ended on this tablet or closed by the backend is never adopted as live,
  /// and a live session is only *confirmed* when the read started after the
  /// realtime channel last came up and it is still up. Returns whether the
  /// backend answered.
  ///
  /// A known state never becomes *unknown* because the call failed. A live
  /// session stays live — a tablet that lost Wi-Fi must not tell the user the
  /// assistance is over — and a confirmed "no session" stays that way. A
  /// failed read never confirms anything either: a suspended session stays
  /// suspended and its grace period keeps running.
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

    final epoch = _authorityEpoch;
    final Result<RemoteSession?> result;
    _readsInFlight++;
    try {
      result = await _loadCurrentRemoteSession();
    } finally {
      _readsInFlight--;
    }
    if (generation != _generation) return false;
    try {
      return await _adopt(emit, result, epoch, generation, reason);
    } finally {
      // Whatever the answer, a session still suspended gets its next re-read.
      _ensureRetry(state);
    }
  }

  Future<bool> _adopt(
    Emitter<RemoteSessionState> emit,
    Result<RemoteSession?> result,
    int epoch,
    int generation,
    Failure? reason,
  ) async {
    switch (result) {
      case Ok<RemoteSession?>(:final value):
        await _settleConfirmation(value);
        if (generation != _generation) return false;
        _noteDeparture(value);
        emit(
          _stateFor(
            value,
            lastFailure: reason,
            authority: _authorityFor(epoch),
          ),
        );
        return true;
      case Err<RemoteSession?>(:final failure):
        // Read *now*, not before the call: a FINALIZAR or a closure that
        // happened while this read was in flight has already moved the state,
        // and that is what stands.
        emit(switch (state) {
          RemoteSessionLive(:final session, :final authority) => _stateFor(
            session,
            lastFailure: reason,
            // Kept only if it is still confirmed: a failure never upgrades.
            authority:
                authority == RemoteSessionAuthority.confirmed &&
                    _authorityChannelUp
                ? RemoteSessionAuthority.confirmed
                : RemoteSessionAuthority.suspended,
          ),
          RemoteSessionEndedLocally(:final remoteSessionId) => _endedState(
            remoteSessionId,
            lastFailure: reason ?? failure,
          ),
          RemoteSessionClosedRemotely(:final remoteSessionId, :final endedBy) =>
            RemoteSessionClosedRemotely(
              remoteSessionId,
              endedBy: endedBy,
              lastFailure: reason ?? failure,
            ),
          // "There is no session" was established by the backend once; a
          // re-read that could not reach it does not un-establish it.
          RemoteSessionIdle(:final lastClosure) => RemoteSessionIdle(
            lastFailure: reason,
            lastClosure: lastClosure,
          ),
          _ => RemoteSessionUnavailable(reason ?? failure),
        });
        return false;
    }
  }

  /// Keeps [_lastClosure] in step with a successful read: the session the
  /// tablet was taking part in is gone without FINALIZAR here, or a new one has
  /// begun.
  void _noteDeparture(RemoteSession? live) {
    final previous = state;
    final heldId = switch (previous) {
      RemoteSessionLive(:final session) => session.id,
      RemoteSessionClosedRemotely(:final remoteSessionId) => remoteSessionId,
      _ => null,
    };
    if (heldId != null && (live == null || live.id != heldId)) {
      final closedBy = _closedRemotely[heldId];
      final wasSuspended =
          previous is RemoteSessionLive && previous.isSuspended;
      if (closedBy == null && wasSuspended) {
        // Found gone by a read made while the tablet could not confirm it, and
        // nobody said who closed it: it went during a connection problem.
        // Most likely the backend's SYSTEM close; possibly the technician.
        _lastClosure = null;
        _interrupted = true;
      } else {
        _lastClosure = closedBy ?? RemoteSessionEndedBy.unknown;
        _interrupted = false;
      }
    }
    if (live != null &&
        _isLiveStatus(live.status) &&
        !_endedHere.contains(live.id) &&
        !_closedRemotely.containsKey(live.id)) {
      _lastClosure = null;
      _interrupted = false;
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
        if (!_closeOwed(remoteSessionId)) {
          // Stopped here because authority was lost: there is no close to
          // send (it would read as the user's FINALIZAR). Asking again is all
          // there is to do.
          await _syncAndReconcile(emit);
          return;
        }
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
  /// realtime payload.
  Future<void> _endHere(
    Emitter<RemoteSessionState> emit,
    String remoteSessionId, {
    RemoteSessionLocalEndReason reason =
        RemoteSessionLocalEndReason.userRequest,
  }) async {
    final generation = _generation;
    // Only the user's own FINALIZAR is reported to the backend: that call is
    // recorded as `endedBy: DEVICE`, and an end the user did not ask for must
    // not read like one. See [_onAuthorityGraceExpired].
    final closeOwed = reason == RemoteSessionLocalEndReason.userRequest;
    _endedHere.add(remoteSessionId);
    _endReasons[remoteSessionId] = reason;
    _lastClosure = null;
    _interrupted = !closeOwed;
    final token = closeOwed ? _confirming = Object() : null;
    emit(_endedState(remoteSessionId));
    _log('assistance ended on this tablet for $remoteSessionId');

    // Remembered before the backend is told, so that an application killed
    // while the close is in flight still refuses this session when it starts
    // again. The marker never gates the end itself: a store that cannot be
    // written costs the restart guarantee, not the local revocation.
    await _loadMarker();
    await _rememberPending(remoteSessionId, closeOwed: closeOwed);
    if (generation != _generation) {
      if (token != null && identical(_confirming, token)) _confirming = null;
      return;
    }
    if (token == null) return;

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
        case Ok<RemoteSession>(:final value)
            when value.confirmsCloseOf(remoteSessionId):
          // `200` with this very session `CLOSED`: confirmed. The close is
          // idempotent, so this is the answer to the first close, to a repeat
          // after a lost response, and to a close the technician or the backend
          // made first — `endedBy` says which, and any of them is a
          // confirmation. The screen can leave the assistance at once...
          _log(
            'close of $remoteSessionId confirmed by the backend '
            '(endedBy ${value.endedBy?.name ?? 'absent'})',
          );
          await _forgetPending(remoteSessionId);
          if (generation != _generation) return;
          done();
          emit(_stateFor(value));
          // ...and the contract's own recovery call agrees. Normally `null`.
          await _sync(emit);
        case Ok<RemoteSession>(:final value):
          // `200` that does not say this session is closed: another id, a
          // status other than `CLOSED`, or no `endedAt`. Not the documented
          // answer, so not a confirmation — and never a reason to adopt what it
          // carries: the session stays ended here, its marker stays, and
          // `/current` decides, exactly as after a `404`. One read, no second
          // close: the next cue reconciles it, as after any other failure.
          _log(
            'close of $remoteSessionId answered 200 without confirming it '
            '(same id: ${value.id == remoteSessionId}, '
            'status: ${value.status.name}, '
            'endedAt: ${value.endedAt == null ? 'absent' : 'present'}): '
            'asking /current',
          );
          done();
          await _sync(emit, reason: const ServerFailure());
        case Err<RemoteSession>(:final failure) when _meansStaleState(failure):
          // `404`: no session of this device has that id — what this client
          // believed is not what the backend holds.
          // `409`: the session is still live but its request cannot complete;
          // nothing was written.
          // An already-`CLOSED` session of this device is neither: it answers
          // `200` (above). Nothing is guessed here either; the backend is
          // asked, and whatever it answers this session stays ended here.
          done();
          await _sync(emit, reason: failure);
        case Err<RemoteSession>(:final failure):
          // Network, 5xx, 401, 400: nothing is known to have happened at the
          // backend. The assistance is still over on this tablet — that was
          // never the backend's to decide — and only the confirmation is
          // pending.
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
    _authorityEpoch++;
    _confirming = null;
    _lastClosure = null;
    _interrupted = false;
    // [_endedHere], [_closedRemotely] and the stored marker are deliberately
    // kept. A session that is over does not become acceptable because the
    // identity was reset.
    emit(const RemoteSessionInitial());
  }

  @override
  Future<void> close() {
    _cancelGrace();
    _cancelRetry();
    return super.close();
  }

  // ---------------------------------------------------------------- marker

  Future<void> _loadMarker() => _markerLoaded ??= _readMarker();

  Future<void> _readMarker() async {
    try {
      final marker = await _endedSessionStore.read();
      if (marker == null) return;
      final remoteSessionId = marker.remoteSessionId;
      _endedHere.add(remoteSessionId);
      if (!marker.closeOwed) {
        _endReasons.putIfAbsent(
          remoteSessionId,
          () => RemoteSessionLocalEndReason.authorityLost,
        );
      }
      _pendingConfirmation ??= remoteSessionId;
      _log(
        'session $remoteSessionId was ended on this tablet before: '
        'it will not be resumed',
      );
    } on EndedRemoteSessionStoreException {
      _log('the ended-session marker could not be read');
    }
  }

  Future<void> _rememberPending(
    String remoteSessionId, {
    required bool closeOwed,
  }) async {
    _pendingConfirmation = remoteSessionId;
    try {
      await _endedSessionStore.write(
        EndedRemoteSessionMarker(remoteSessionId, closeOwed: closeOwed),
      );
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

  /// Whether a session ended here is one the backend must be told about with
  /// `POST close` (FINALIZAR), as opposed to one the backend closes itself.
  bool _closeOwed(String remoteSessionId) =>
      _endReasons[remoteSessionId] != RemoteSessionLocalEndReason.authorityLost;

  /// `404` and `409` both mean the same thing here: what this client believed
  /// is not what the backend holds, and the close did not happen. The contract
  /// is explicit that the client re-reads state rather than interpreting the
  /// message. Neither stands for "already closed" any more: that is a `200`.
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
    reason:
        _endReasons[remoteSessionId] ?? RemoteSessionLocalEndReason.userRequest,
  );

  RemoteSessionLive _withAuthority(
    RemoteSessionLive live,
    RemoteSessionAuthority authority,
  ) => switch (live) {
    RemoteSessionConnecting(:final session, :final lastFailure) =>
      RemoteSessionConnecting(
        session,
        authority: authority,
        lastFailure: lastFailure,
      ),
    RemoteSessionActive(:final session, :final lastFailure) =>
      RemoteSessionActive(
        session,
        authority: authority,
        lastFailure: lastFailure,
      ),
  };

  /// The single mapping from a backend payload to a screen state.
  ///
  /// [authority] defaults to suspended: only a caller that has established a
  /// fresh read with the channel up may say otherwise.
  RemoteSessionState _stateFor(
    RemoteSession? session, {
    Failure? lastFailure,
    RemoteSessionAuthority authority = RemoteSessionAuthority.suspended,
  }) {
    if (session == null) {
      return RemoteSessionIdle(
        lastFailure: lastFailure,
        lastClosure: _lastClosure,
        interrupted: _lastClosure == null && _interrupted,
      );
    }

    // The places a backend answer is overruled, and only in one direction: a
    // session that is over here is reported as over, never as live.
    if (_isLiveStatus(session.status)) {
      if (_endedHere.contains(session.id)) {
        return _endedState(session.id, lastFailure: lastFailure);
      }
      final endedBy = _closedRemotely[session.id];
      if (endedBy != null) {
        return RemoteSessionClosedRemotely(
          session.id,
          endedBy: endedBy,
          lastFailure: lastFailure,
        );
      }
    }

    return switch (session.status) {
      RemoteSessionStatus.connecting => RemoteSessionConnecting(
        session,
        authority: authority,
        lastFailure: lastFailure,
      ),
      RemoteSessionStatus.active => RemoteSessionActive(
        session,
        authority: authority,
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
