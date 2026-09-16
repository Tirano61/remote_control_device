import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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
/// The interesting part is what happens when a handshake is refused. The
/// backend answers a single generic `Unauthorized` whether the Device JWT
/// merely expired — which it will, after 24h, on a tablet left running — or the
/// permanent credential was revoked. The two cannot be told apart from the
/// socket, so the client asks the question that *can* be answered:
///
/// ```text
/// handshake refused
///        ↓
/// stop reconnecting with the refused token
///        ↓
/// POST /device-auth/login with deviceId + deviceSecret
///        ├── 200 ──> new Device JWT ──> new socket ──> connected
///        ├── 401 ──> the credential itself is gone ──> re-enrollment
///        └── offline/5xx ──> credential preserved ──> retry later
/// ```
///
/// Exactly one such recovery is attempted per connection. If a *freshly issued*
/// token is refused as well, re-authenticating again would only repeat the same
/// exchange, so the client stops instead of spinning through logins.
class DeviceRealtimeBloc
    extends Bloc<DeviceRealtimeEvent, DeviceRealtimeState> {
  DeviceRealtimeBloc({
    required DeviceRealtimeClient client,
    required DeviceTokenStore tokenStore,
    required RenewDeviceToken renewDeviceToken,
    Duration reauthRetryDelay = const Duration(seconds: 15),
  }) : _client = client,
       _tokenStore = tokenStore,
       _renewDeviceToken = renewDeviceToken,
       _reauthRetryDelay = reauthRetryDelay,
       super(const DeviceRealtimeDisconnected()) {
    on<DeviceRealtimeStartRequested>(_onStartRequested);
    on<DeviceRealtimeStopRequested>(_onStopRequested);
    on<_SignalReceived>(_onSignalReceived);
    on<_ReauthRetryDue>(_onReauthRetryDue);

    _signals = _client.signals.listen((signal) => add(_SignalReceived(signal)));
  }

  final DeviceRealtimeClient _client;
  final DeviceTokenStore _tokenStore;
  final RenewDeviceToken _renewDeviceToken;
  final Duration _reauthRetryDelay;

  late final StreamSubscription<DeviceRealtimeSignal> _signals;

  /// Token the current socket was built with. `null` means no channel is
  /// wanted, which is also what makes late signals from a released socket safe
  /// to ignore. Never leaves this object.
  String? _activeToken;

  /// Whether a connection succeeded since the channel was last started. It is
  /// the difference between "cannot reach the backend" and "lost a working
  /// connection", which is the only thing the user actually needs told apart.
  bool _hasConnected = false;

  /// Guards against concurrent logins when several handshake rejections arrive
  /// close together.
  bool _renewing = false;

  /// Whether the token in use came from a renewal. Reset on every successful
  /// connection, so the single-recovery budget is per connection, not per app
  /// run.
  bool _renewedSinceLastConnection = false;

  Timer? _reauthRetry;

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

    _cancelReauthRetry();
    _activeToken = token;
    _hasConnected = false;
    _renewedSinceLastConnection = false;
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

  Future<void> _onSignalReceived(
    _SignalReceived event,
    Emitter<DeviceRealtimeState> emit,
  ) async {
    // Anything arriving after the channel was released belongs to a socket the
    // app has already walked away from.
    if (_activeToken == null) return;

    switch (event.signal) {
      case RealtimeConnected():
        _hasConnected = true;
        _renewedSinceLastConnection = false;
        _cancelReauthRetry();
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
      case RealtimeConnectFailed():
        emit(_failureState());

      case RealtimeReconnectAttempt():
        emit(_attemptState());

      case RealtimeHandshakeRejected():
        await _recoverFromRejectedHandshake(emit);
    }
  }

  Future<void> _onReauthRetryDue(
    _ReauthRetryDue event,
    Emitter<DeviceRealtimeState> emit,
  ) async {
    if (_activeToken == null) return;
    await _renewAndReconnect(emit);
  }

  Future<void> _recoverFromRejectedHandshake(
    Emitter<DeviceRealtimeState> emit,
  ) async {
    if (_renewing) return;

    if (_renewedSinceLastConnection) {
      // The token this socket presented was minted moments ago and was refused
      // anyway. Another login would return an equally fresh token and be
      // refused in turn, so stop rather than loop.
      _stop(emit, const DeviceRealtimeConnectionError(retrying: false));
      return;
    }

    await _renewAndReconnect(emit);
  }

  Future<void> _renewAndReconnect(Emitter<DeviceRealtimeState> emit) async {
    _renewing = true;
    _cancelReauthRetry();
    // Stop presenting the refused token before asking for a new one: Socket.IO
    // resends `auth` on every attempt and would keep failing on the old value.
    _client.disconnect();
    emit(_attemptState());

    try {
      final renewal = await _renewDeviceToken();
      if (_activeToken == null) return;

      switch (renewal) {
        case DeviceTokenRenewed(:final token):
          // The renewal already installed the token in the store; holding it
          // here is only how the next signal is matched to this socket.
          _activeToken = token;
          _renewedSinceLastConnection = true;
          emit(_attemptState());
          _client.connect(token);

        case DeviceTokenRejected():
          _stop(
            emit,
            const DeviceRealtimeDisconnected(
              cause: DeviceRealtimeStopCause.credentialRejected,
            ),
          );

        case DeviceTokenRenewalUnavailable():
          // Nothing was learnt about the credential, so it stays where it is
          // and the attempt is repeated on a slow timer.
          _scheduleReauthRetry();
          emit(const DeviceRealtimeConnectionError());
      }
    } finally {
      _renewing = false;
    }
  }

  void _stop(Emitter<DeviceRealtimeState> emit, DeviceRealtimeState next) {
    _cancelReauthRetry();
    _activeToken = null;
    _hasConnected = false;
    _renewedSinceLastConnection = false;
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

  void _scheduleReauthRetry() {
    _reauthRetry?.cancel();
    _reauthRetry = Timer(_reauthRetryDelay, () => add(const _ReauthRetryDue()));
  }

  void _cancelReauthRetry() {
    _reauthRetry?.cancel();
    _reauthRetry = null;
  }

  @override
  Future<void> close() async {
    _cancelReauthRetry();
    await _signals.cancel();
    await _client.dispose();
    return super.close();
  }
}
