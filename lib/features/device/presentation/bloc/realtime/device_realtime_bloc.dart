import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/core/async/timer_factory.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/domain/entities/device_realtime_confirmation.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_client.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
import 'package:remote_control_device/features/device/domain/realtime/heartbeat_watchdog.dart';
import 'package:remote_control_device/features/device/domain/realtime/realtime_heartbeat_policy.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';

part 'device_realtime_event.dart';
part 'device_realtime_state.dart';

/// Owns the Socket.IO channel to `/devices`.
///
/// Kept apart from `DeviceSessionBloc` on purpose: that bloc answers whether
/// this installation is a valid device, over HTTP; this one answers whether the
/// realtime channel is up right now. The application layer coordinates them;
/// neither reaches into the other.
///
/// ## When the transport cannot recover by itself
///
/// A lost transport is the package's to retry, with the same socket and the
/// same token. Four things destroy the socket instead, and then only this bloc
/// can open another one:
///
/// ```text
/// DEVICE_AUTH_UNAUTHORIZED            expired JWT, deactivated device, revoked
///   (or a bare Unauthorized from a    credential (an old backend also sent it
///   backend older than the codes)     when its own check failed)
/// io server disconnect                the backend withdrew the authorisation
///                                     of an open socket
/// unrecognised namespace refusal      an unknown code, a malformed body,
///                                     another message
/// DEVICE_AUTH_UNAVAILABLE             the backend could not check the token
/// ```
///
/// None of them proves anything about the permanent credential. The first
/// three say, or may say, something about the *token*, so they are answered by
/// asking the question that can be answered:
///
/// ```text
/// release the socket
///        ↓
/// POST /device-auth/login with deviceId + deviceSecret
///        ├── 200 ──> new Device JWT ──> new socket
///        ├── 401 DEVICE_CREDENTIAL_REJECTED ──> stop; the session withdraws
///        │          authorisation (the credential is kept, nothing retried)
///        └── anything else ──> nothing learnt; retried after
///                   [reauthRetryDelay]
/// ```
///
/// `DEVICE_AUTH_UNAVAILABLE` says nothing about the token, and a login would
/// hit the same failing database, so it costs no login:
///
/// ```text
/// release the socket ──> backoff ──> new socket with the current Device JWT
/// ```
///
/// "Current" is whatever the token store holds when the retry comes due: the
/// same token, or a newer one if REST renewed it in the meantime — never an
/// older one. If that token has expired by then, the backend answers
/// `DEVICE_AUTH_UNAUTHORIZED` (expiry is checked before the database), and that
/// is renewed like any other refusal. Keeping the token is not trusting it: the
/// state is never `Connected` until a handshake is accepted.
///
/// Before any renewal, the store is read too: when it already holds a token
/// newer than the refused one, that token is presented instead of logging in.
///
/// ## Bounded, never terminal
///
/// The first renewal since the last stable connection runs at once — a JWT
/// that merely expired after a day of uptime is renewed without delay. Every
/// further one waits on [recoveryBackoff] (15 s, 30 s, 60 s, then 60 s for as
/// long as it takes). An unavailable backend is never retried at once: its
/// first retry already waits the first step. Both kinds share one count, which
/// only resets when a connection that had stayed up for at least
/// [stableConnectionPeriod] is lost, so a backend that accepts and immediately
/// drops the socket costs one attempt a minute, not one per drop. No timer
/// runs while connected: stability is read off the clock when the connection
/// ends.
///
/// It never gives up on its own: a freshly minted JWT refused twice in a row is
/// what a database blip looks like from here, and it heals. The only thing that
/// stops the channel is the session — a confirmed refusal, an explicit stop, a
/// lost identity — or closing the bloc.
///
/// ## Generations
///
/// Every start, stop and close begins a new generation. Every asynchronous
/// continuation — a login answer, a due timer — carries the generation that
/// began it and does nothing if it is no longer the current one: it installs
/// no socket, adopts no token, emits nothing and schedules nothing. Signals of
/// a released socket never arrive at all (the client drops them), and anything
/// arriving while no channel is wanted is ignored.
///
/// Logins are also serialised, across generations: a renewal never starts
/// while another one is still waiting for its answer.
///
/// ## Heartbeat
///
/// A connection the transport still calls up may be dead: a half-open TCP
/// connection is only noticed by socket_io_client's own `ping timeout`,
/// `pingInterval + pingTimeout` (20 s) after the last `PING`. The
/// [HeartbeatWatchdog] notices sooner (13 s with the backend's 10/10), and
/// this bloc then reports [DeviceRealtimeHeartbeatOverdue] — which everything
/// downstream reads as "not connected", so the session's authority is
/// suspended through its usual path. Nothing here closes the socket for that:
///
/// ```text
/// connected ──(no PING for pingInterval + 3 s)──> heartbeat overdue
///   overdue ──(a PING on the same socket)───────> connected (and the session
///                                                 must be confirmed again)
///   overdue ──(the transport gives up)──────────> reconnecting, as always
///   overdue ──(pingInterval + pingTimeout + 5 s
///              and the transport has not)──────> a new socket, same token
/// ```
///
/// The watch belongs to the connection: every connection starts one, and
/// every loss, stop and generation ends it, so a timer or a `PING` of a
/// previous connection cannot speak for the current one.
class DeviceRealtimeBloc
    extends Bloc<DeviceRealtimeEvent, DeviceRealtimeState> {
  DeviceRealtimeBloc({
    required DeviceRealtimeClient client,
    required DeviceTokenStore tokenStore,
    required RenewDeviceToken renewDeviceToken,
    Duration reauthRetryDelay = const Duration(seconds: 15),
    List<Duration> recoveryBackoff = defaultRecoveryBackoff,
    Duration stableConnectionPeriod = defaultStableConnectionPeriod,
    TimerFactory timerFactory = systemTimerFactory,
    DateTime Function() clock = DateTime.now,
    HeartbeatWatchdog? heartbeatWatchdog,
  }) : assert(recoveryBackoff.isNotEmpty, 'the backoff needs a step'),
       _client = client,
       _tokenStore = tokenStore,
       _renewDeviceToken = renewDeviceToken,
       _reauthRetryDelay = reauthRetryDelay,
       _recoveryBackoff = recoveryBackoff,
       _stableConnectionPeriod = stableConnectionPeriod,
       _timerFactory = timerFactory,
       _clock = clock,
       _watchdog = heartbeatWatchdog ?? HeartbeatWatchdog(),
       super(const DeviceRealtimeDisconnected()) {
    on<DeviceRealtimeStartRequested>(_onStartRequested);
    on<DeviceRealtimeStopRequested>(_onStopRequested);
    on<_SignalReceived>(_onSignalReceived);
    on<_RetryDue>(_onRetryDue);
    on<_HeartbeatOverdue>(_onHeartbeatOverdue);
    on<_HeartbeatStalled>(_onHeartbeatStalled);

    _signals = _client.signals.listen((signal) => add(_SignalReceived(signal)));
  }

  /// Delays before the second, third, fourth... recovery since the last stable
  /// connection. The last one repeats.
  static const List<Duration> defaultRecoveryBackoff = [
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];

  /// How long a connection must stay up before the next recovery runs at once
  /// again.
  static const Duration defaultStableConnectionPeriod = Duration(seconds: 30);

  final DeviceRealtimeClient _client;
  final DeviceTokenStore _tokenStore;
  final RenewDeviceToken _renewDeviceToken;
  final Duration _reauthRetryDelay;
  final List<Duration> _recoveryBackoff;
  final Duration _stableConnectionPeriod;
  final TimerFactory _timerFactory;
  final DateTime Function() _clock;
  final HeartbeatWatchdog _watchdog;

  static const String _loggerName = 'realtime';

  late final StreamSubscription<DeviceRealtimeSignal> _signals;

  /// See the class documentation. Never decreases.
  int _generation = 0;

  /// Token the current socket was built with. `null` means no channel is
  /// wanted, which is also what makes late signals safe to ignore. Never
  /// leaves this object.
  String? _activeToken;

  /// Whether a connection succeeded since the channel was last started. It is
  /// the difference between "cannot reach the backend" and "lost a working
  /// connection", which is the only thing the user actually needs told apart.
  bool _hasConnected = false;

  /// A renewal of the current generation is waiting for its answer.
  bool _renewing = false;

  /// Recoveries since the last stable connection; picks the next delay.
  int _recoveries = 0;

  /// The one deferred retry, if any. Never more than one.
  Timer? _retryTimer;

  /// When the current connection came up; `null` while not connected. Read
  /// when it is lost, to decide whether it counted as stable.
  DateTime? _connectedSince;

  /// Tail of the login queue: the next renewal starts only after it.
  Future<void> _loginTail = Future<void>.value();

  // ------------------------------------------------------------ lifecycle

  Future<void> _onStartRequested(
    DeviceRealtimeStartRequested event,
    Emitter<DeviceRealtimeState> emit,
  ) async {
    final token = _tokenStore.token;
    if (token == null) {
      // Ready without a token cannot happen through the session flow, but the
      // channel must not be opened unauthenticated if it ever did.
      _stop(emit, const DeviceRealtimeDisconnected());
      return;
    }
    // A session that is already live must not be torn down and rebuilt just
    // because the request was repeated.
    if (token == _activeToken && state is! DeviceRealtimeDisconnected) return;

    _beginGeneration();
    _activeToken = token;
    _hasConnected = false;
    _recoveries = 0;
    emit(const DeviceRealtimeConnecting());
    _client.connect(token);
  }

  Future<void> _onStopRequested(
    DeviceRealtimeStopRequested event,
    Emitter<DeviceRealtimeState> emit,
  ) async {
    if (_activeToken == null && state is DeviceRealtimeDisconnected) return;
    _stop(emit, const DeviceRealtimeDisconnected());
  }

  // -------------------------------------------------------------- signals

  Future<void> _onSignalReceived(
    _SignalReceived event,
    Emitter<DeviceRealtimeState> emit,
  ) async {
    // Nothing is wanted: whatever this is, it belongs to a socket the app has
    // already walked away from.
    if (_activeToken == null) return;

    switch (event.signal) {
      case RealtimeConnected(:final heartbeat):
        _hasConnected = true;
        _cancelRetry();
        _connectedSince = _clock();
        _watchHeartbeat(heartbeat);
        emit(const DeviceRealtimeConnected());

      case RealtimeHeartbeat():
        _onHeartbeat(emit);

      case RealtimeIdentityConfirmed(:final confirmation):
        // A confirmation annotates a live connection; it never establishes one.
        if (state is! DeviceRealtimeConnected) return;
        emit(DeviceRealtimeConnected(confirmation: confirmation));

      case RealtimeSupportAssigned():
      case RealtimeRemoteSessionCreated():
      case RealtimeRemoteSessionActivated():
      case RealtimeRemoteSessionClosed():
        // Not this bloc's business. It owns whether the channel is up, not what
        // travels over it; the support and remote-session features subscribe to
        // the same broadcast signal stream and answer by re-reading REST.
        return;

      case RealtimeDisconnected():
      case RealtimeConnectFailed(transportRetrying: true):
        // The package retries this one itself, with the same socket.
        _noteConnectionLost();
        emit(_failureState());

      case RealtimeReconnectAttempt():
        emit(_attemptState());

      case RealtimeHandshakeRejected():
      case RealtimeServerDisconnected():
      case RealtimeConnectFailed(transportRetrying: false):
        // The socket is gone and nothing will open another one but this bloc.
        _noteConnectionLost();
        await _recover(emit, renew: true);

      case RealtimeHandshakeUnavailable():
        // Gone too, but the token was not judged: keep it, renew nothing.
        _noteConnectionLost();
        await _recover(emit, renew: false);
    }
  }

  // ------------------------------------------------------------ heartbeat

  void _watchHeartbeat(RealtimeHeartbeatPolicy? policy) {
    _watchdog.start(
      policy,
      onOverdue: (watch) {
        if (!isClosed) add(_HeartbeatOverdue(watch));
      },
      onStalled: (watch) {
        if (!isClosed) add(_HeartbeatStalled(watch));
      },
    );
    if (policy == null) {
      _log('heartbeat not announced: this connection is not watched');
    }
  }

  void _onHeartbeat(Emitter<DeviceRealtimeState> emit) {
    final current = state;
    // A PING before the namespace accepted the connection, or after it was
    // lost: nothing is being watched, and nothing is learnt from it.
    if (current is! DeviceRealtimeConnected &&
        current is! DeviceRealtimeHeartbeatOverdue) {
      return;
    }
    final beat = _watchdog.beat();
    if (beat == null) return;
    final gap = beat.gap;
    if (current is DeviceRealtimeConnected && beat.afterUnseenLapse) {
      // The heartbeat stopped vouching for the authority longer than it may,
      // and nobody declared it: this isolate's timers did not run (it was
      // held, or the process slept). The native transmission lease ran out at
      // the deadline on its own; here it is the overdue that is already over,
      // both states in a row: the coordinators suspend the session and, the
      // channel being up again, confirm it over REST before anything goes on.
      final policy = _watchdog.policy!;
      _log(
        'heartbeat lapsed unseen: PING after ${_seconds(gap)} (limit '
        '${_seconds(_watchdog.thresholdFor(policy))}); the session is '
        'suspended and must be confirmed again',
      );
      emit(DeviceRealtimeHeartbeatOverdue(confirmation: current.confirmation));
      emit(DeviceRealtimeConnected(confirmation: current.confirmation));
      return;
    }
    if (current is DeviceRealtimeHeartbeatOverdue) {
      // The channel counts as up again, and only that. The coordinator reads
      // it as a reconnection: the session stays suspended until a REST read
      // made after this instant confirms it, and the room is joined again
      // only then.
      _log(
        'heartbeat back: PING after ${_seconds(gap)}; the channel is up '
        'again, the session must be confirmed again',
      );
      emit(DeviceRealtimeConnected(confirmation: current.confirmation));
    } else {
      _log('heartbeat: PING after ${_seconds(gap)}');
    }
  }

  Future<void> _onHeartbeatOverdue(
    _HeartbeatOverdue event,
    Emitter<DeviceRealtimeState> emit,
  ) async {
    // Raised for a connection since replaced, or already settled by a PING
    // that arrived while this event was queued.
    if (event.watch != _watchdog.watch || !_watchdog.isOverdue) return;
    final current = state;
    if (current is! DeviceRealtimeConnected) return;
    final policy = _watchdog.policy!;
    _log(
      'heartbeat overdue: no PING for ${_seconds(_watchdog.evidenceAge!)} '
      '(limit ${_seconds(_watchdog.thresholdFor(policy))}, heartbeat '
      '$policy); the channel counts as down until the next PING',
    );
    emit(DeviceRealtimeHeartbeatOverdue(confirmation: current.confirmation));
  }

  Future<void> _onHeartbeatStalled(
    _HeartbeatStalled event,
    Emitter<DeviceRealtimeState> emit,
  ) async {
    if (event.watch != _watchdog.watch) return;
    if (state is! DeviceRealtimeHeartbeatOverdue) return;
    final token = _activeToken;
    if (token == null) return;
    // socket_io_client should have closed it on its own `ping timeout` by
    // now. It has not, and the tablet would otherwise stay suspended on a
    // socket that can never be confirmed again. The token was not judged: the
    // same one opens the next socket, and a refusal of it renews as usual.
    _log(
      'heartbeat stalled: no PING for ${_seconds(_watchdog.evidenceAge!)} and '
      'the transport has not given up; a new socket replaces it',
    );
    _noteConnectionLost();
    emit(const DeviceRealtimeReconnecting());
    _client.connect(token);
  }

  static String _seconds(Duration duration) =>
      '${(duration.inMilliseconds / 1000).toStringAsFixed(2)} s';

  void _log(String message) {
    if (kDebugMode) developer.log(message, name: _loggerName);
  }

  // ------------------------------------------------------------- recovery

  /// Releases the dead socket and opens the next one — renewing the token
  /// first when [renew], presenting the current one again otherwise — either
  /// at once or on the backoff. One recovery at a time: a login in flight or a
  /// retry already scheduled will open the next socket.
  Future<void> _recover(
    Emitter<DeviceRealtimeState> emit, {
    required bool renew,
  }) async {
    if (_renewing || _retryTimer != null) return;

    // Stop presenting the token before anything else, and never reuse a
    // destroyed socket: the next one is built from scratch.
    _client.disconnect();

    final attempt = _recoveries++;
    if (renew && attempt == 0) {
      await _renewAndReconnect(emit);
      return;
    }
    // A renewal that cannot run at once waits from the first step; so does an
    // unavailable backend, which is never retried at once — it has just said
    // it cannot answer.
    final step = math.min(renew ? attempt - 1 : attempt, _lastStep);
    _scheduleRetry(_recoveryBackoff[step], renew: renew);
    emit(_failureState());
  }

  int get _lastStep => _recoveryBackoff.length - 1;

  Future<void> _onRetryDue(
    _RetryDue event,
    Emitter<DeviceRealtimeState> emit,
  ) async {
    // A timer of an earlier generation: stopped, restarted or closed since.
    if (event.generation != _generation || _activeToken == null) return;
    _retryTimer = null;
    if (event.renew) {
      await _renewAndReconnect(emit);
    } else {
      _reconnectWithCurrentToken(emit);
    }
  }

  /// The retry after `DEVICE_AUTH_UNAVAILABLE`: a new socket, no login.
  void _reconnectWithCurrentToken(Emitter<DeviceRealtimeState> emit) {
    // Read now, not when the refusal arrived: REST may have renewed it since,
    // and the newest token is the one worth presenting.
    final token = _tokenStore.token;
    if (token == null) {
      // Authorisation was withdrawn while waiting; the session is about to
      // stop the channel. Nothing is presented, nothing is scheduled.
      emit(_failureState());
      return;
    }
    _activeToken = token;
    emit(_attemptState());
    _client.connect(token);
  }

  Future<void> _renewAndReconnect(Emitter<DeviceRealtimeState> emit) async {
    // A token newer than the refused one is already installed — REST renewed
    // it while this recovery waited. Present it; a login would only mint
    // another one. If it is refused too, that refusal renews.
    final installed = _tokenStore.token;
    if (installed != null && installed != _activeToken) {
      _cancelRetry();
      _activeToken = installed;
      emit(_attemptState());
      _client.connect(installed);
      return;
    }

    final generation = _generation;
    _renewing = true;
    _cancelRetry();
    emit(_attemptState());

    try {
      final renewal = await _renewSerially();
      // Stopped, restarted or closed while the login was in flight: its answer
      // installs nothing here. (A token it obtained was already written to the
      // store by the repository; it is as valid as any other for the same
      // credential, and the session decides what the store holds next.)
      if (generation != _generation) return;

      switch (renewal) {
        case DeviceTokenRenewed(:final token):
          if (!_tokenStore.hasToken) {
            // Authorisation was withdrawn while the login was on the wire, so
            // the repository did not install the token. The session is about
            // to stop the channel; this token opens nothing.
            emit(_failureState());
            return;
          }
          // The renewal already installed the token in the store; holding it
          // here is only how a repeated start is told apart from a new one.
          _activeToken = token;
          _client.connect(token);

        case DeviceTokenRejected():
          // Confirmed: the backend refused the permanent credential. Reported
          // through the state; the coordinator hands it to the session, which
          // withdraws authorisation and keeps the credential. Nothing here
          // retries it.
          _stop(
            emit,
            const DeviceRealtimeDisconnected(
              cause: DeviceRealtimeStopCause.credentialRejected,
            ),
          );

        case DeviceTokenRenewalUnavailable():
          // Nothing was learnt about the credential, so it stays where it is
          // and the attempt is repeated on a slow timer.
          _scheduleRetry(_reauthRetryDelay);
          emit(const DeviceRealtimeConnectionError());
      }
    } finally {
      if (generation == _generation) _renewing = false;
    }
  }

  Future<DeviceTokenRenewal> _renewSerially() {
    final renewal = _loginTail.then((_) => _renewDeviceToken());
    _loginTail = renewal.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return renewal;
  }

  // ---------------------------------------------------------------- plumbing

  /// Invalidates everything still pending from the previous generation.
  void _beginGeneration() {
    _generation++;
    _renewing = false;
    _cancelRetry();
    _connectedSince = null;
    _watchdog.stop();
  }

  void _stop(Emitter<DeviceRealtimeState> emit, DeviceRealtimeState next) {
    _beginGeneration();
    _activeToken = null;
    _hasConnected = false;
    _recoveries = 0;
    _client.disconnect();
    emit(next);
  }

  /// State while a connection is actively being opened.
  DeviceRealtimeState _attemptState() => _hasConnected
      ? const DeviceRealtimeReconnecting()
      : const DeviceRealtimeConnecting();

  /// State after an attempt failed or a connection dropped.
  DeviceRealtimeState _failureState() => _hasConnected
      ? const DeviceRealtimeReconnecting()
      : const DeviceRealtimeConnectionError();

  void _scheduleRetry(Duration delay, {bool renew = true}) {
    _retryTimer?.cancel();
    final generation = _generation;
    _retryTimer = _timerFactory(delay, () {
      if (!isClosed) add(_RetryDue(generation, renew: renew));
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// A connection that had stayed up for [_stableConnectionPeriod] earns the
  /// next recovery an immediate start again.
  void _noteConnectionLost() {
    // Nothing is watched without a connection: a later PING of a socket the
    // transport is retrying cannot count for it.
    _watchdog.stop();
    final since = _connectedSince;
    _connectedSince = null;
    if (since != null &&
        _clock().difference(since) >= _stableConnectionPeriod) {
      _recoveries = 0;
    }
  }

  @override
  Future<void> close() async {
    _beginGeneration();
    await _signals.cancel();
    await _client.dispose();
    return super.close();
  }
}
