import 'dart:async';
import 'dart:math' as math;

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/core/async/timer_factory.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/domain/entities/device_realtime_confirmation.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_client.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
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
/// same token. Three things destroy the socket instead, and then only this bloc
/// can open another one:
///
/// ```text
/// handshake refused (Unauthorized)    expired JWT, deactivated device, revoked
///                                     credential — or a backend that failed to
///                                     check (a database error reads the same)
/// io server disconnect                the backend withdrew the authorisation
///                                     of an open socket
/// other namespace refusal             anything else that destroyed the socket
/// ```
///
/// None of them proves anything about the permanent credential, so each one is
/// answered the same way — ask the question that *can* be answered:
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
/// ## Bounded, never terminal
///
/// The first recovery since the last stable connection runs at once — a JWT
/// that merely expired after a day of uptime is renewed without delay. Every
/// further one waits on [recoveryBackoff] (15 s, 30 s, 60 s, then 60 s for as
/// long as it takes). The count only resets when a connection that had stayed
/// up for at least [stableConnectionPeriod] is lost, so a backend that accepts
/// and immediately drops the socket costs one login a minute, not one per drop.
/// No timer runs while connected: stability is read off the clock when the
/// connection ends.
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
  }) : assert(recoveryBackoff.isNotEmpty, 'the backoff needs a step'),
       _client = client,
       _tokenStore = tokenStore,
       _renewDeviceToken = renewDeviceToken,
       _reauthRetryDelay = reauthRetryDelay,
       _recoveryBackoff = recoveryBackoff,
       _stableConnectionPeriod = stableConnectionPeriod,
       _timerFactory = timerFactory,
       _clock = clock,
       super(const DeviceRealtimeDisconnected()) {
    on<DeviceRealtimeStartRequested>(_onStartRequested);
    on<DeviceRealtimeStopRequested>(_onStopRequested);
    on<_SignalReceived>(_onSignalReceived);
    on<_RetryDue>(_onRetryDue);

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
      case RealtimeConnected():
        _hasConnected = true;
        _cancelRetry();
        _connectedSince = _clock();
        emit(const DeviceRealtimeConnected());

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
        await _recover(emit);
    }
  }

  // ------------------------------------------------------------- recovery

  /// Releases the dead socket and either renews at once or schedules the
  /// renewal on the backoff. One recovery at a time: a login in flight or a
  /// retry already scheduled will open the next socket.
  Future<void> _recover(Emitter<DeviceRealtimeState> emit) async {
    if (_renewing || _retryTimer != null) return;

    // Stop presenting the refused token before asking for a new one, and never
    // reuse a destroyed socket: the next one is built from scratch.
    _client.disconnect();

    final attempt = _recoveries++;
    if (attempt == 0) {
      await _renewAndReconnect(emit);
      return;
    }
    final step = math.min(attempt - 1, _recoveryBackoff.length - 1);
    _scheduleRetry(_recoveryBackoff[step]);
    emit(_failureState());
  }

  Future<void> _onRetryDue(
    _RetryDue event,
    Emitter<DeviceRealtimeState> emit,
  ) async {
    // A timer of an earlier generation: stopped, restarted or closed since.
    if (event.generation != _generation || _activeToken == null) return;
    _retryTimer = null;
    await _renewAndReconnect(emit);
  }

  Future<void> _renewAndReconnect(Emitter<DeviceRealtimeState> emit) async {
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

  void _scheduleRetry(Duration delay) {
    _retryTimer?.cancel();
    final generation = _generation;
    _retryTimer = _timerFactory(delay, () {
      if (!isClosed) add(_RetryDue(generation));
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// A connection that had stayed up for [_stableConnectionPeriod] earns the
  /// next recovery an immediate start again.
  void _noteConnectionLost() {
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
