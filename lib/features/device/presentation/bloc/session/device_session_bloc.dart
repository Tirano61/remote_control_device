import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:remote_control_device/core/async/timer_factory.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/device/domain/entities/device_credentials.dart';
import 'package:remote_control_device/features/device/domain/entities/device_identity.dart';
import 'package:remote_control_device/features/device/domain/entities/device_session.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/check_device_status.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/suspend_device_authorization.dart';

part 'device_session_event.dart';
part 'device_session_state.dart';

/// Owns the startup decision, and with it whether this installation is
/// authorised at all:
///
/// ```text
/// local credentials? ──no──> notEnrolled
///        │yes
///        ↓
/// POST /device-auth/login
///        ├── 401 DEVICE_CREDENTIAL_REJECTED ──> credentialRefused
///        ├── anything else that is not 200 ───> authenticationUnavailable
///        ↓ 200
/// GET /device-auth/check-status
///        ├── 200 ──> ready
///        ├── 401 ──> the fresh JWT was not accepted: suspend, log in once more
///        │            ├── 200 + check-status 200 ──> ready
///        │            ├── 401 DEVICE_CREDENTIAL_REJECTED ──> credentialRefused
///        │            └── anything else ──> authenticationUnavailable
///        └── anything else ──> authenticationUnavailable
/// ```
///
/// Three rules hold throughout:
///
/// * **Nothing wipes the credential.** Not an ambiguous answer — a `401` can
///   come from a proxy or a private tunnel — and not a confirmed one either:
///   `DEVICE_CREDENTIAL_REJECTED` is also what a deactivated device gets, and
///   the same credential works again once it is reactivated. The credential is
///   only ever replaced, by a new enrollment the user starts.
/// * **Keeping the credential is not authorisation.** Leaving [DeviceSessionReady]
///   drops the Device JWT first; only a login *and* a check-status accepted by
///   the backend get back there.
/// * **Bounded work.** A refusal is never retried on its own. An unavailable
///   authentication is retried on a capped backoff. A `401` from check-status
///   buys exactly one renewal.
class DeviceSessionBloc extends Bloc<DeviceSessionEvent, DeviceSessionState> {
  DeviceSessionBloc({
    required LoadDeviceCredentials loadDeviceCredentials,
    required AuthenticateDevice authenticateDevice,
    required CheckDeviceStatus checkDeviceStatus,
    required SuspendDeviceAuthorization suspendDeviceAuthorization,
    TimerFactory timerFactory = systemTimerFactory,
    List<Duration> retryBackoff = defaultRetryBackoff,
  }) : assert(retryBackoff.isNotEmpty, 'the backoff needs at least one step'),
       _loadDeviceCredentials = loadDeviceCredentials,
       _authenticateDevice = authenticateDevice,
       _checkDeviceStatus = checkDeviceStatus,
       _suspendDeviceAuthorization = suspendDeviceAuthorization,
       _timerFactory = timerFactory,
       _retryBackoff = retryBackoff,
       super(const DeviceSessionInitial()) {
    on<DeviceSessionStarted>(_onAttemptRequested);
    on<DeviceSessionRetryRequested>(_onAttemptRequested);
    on<DeviceSessionEnrollmentCompleted>(_onAttemptRequested);
    on<_AutomaticRetryDue>(_onAutomaticRetryDue);
    on<DeviceSessionCredentialRejected>(_onCredentialRejected);
    on<DeviceSessionReEnrollmentRequested>(_onReEnrollmentRequested);
    on<DeviceSessionReEnrollmentCancelled>(_onReEnrollmentCancelled);
  }

  /// Delays between automatic attempts while authentication is unavailable.
  /// The last one repeats: the tablet keeps trying, at most once a minute.
  static const List<Duration> defaultRetryBackoff = [
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 40),
    Duration(seconds: 60),
  ];

  final LoadDeviceCredentials _loadDeviceCredentials;
  final AuthenticateDevice _authenticateDevice;
  final CheckDeviceStatus _checkDeviceStatus;
  final SuspendDeviceAuthorization _suspendDeviceAuthorization;
  final TimerFactory _timerFactory;
  final List<Duration> _retryBackoff;

  /// Identifies the attempt in flight. Anything that supersedes it — a newer
  /// attempt, a reported rejection — bumps it, and an attempt that finds it
  /// changed after an `await` stops without emitting. Events are handled
  /// concurrently, so this is what keeps a late login answer from putting a
  /// refused device back in READY.
  int _generation = 0;

  /// Consecutive unavailable outcomes, which picks the next backoff step.
  int _unavailableStreak = 0;

  Timer? _retryTimer;

  Future<void> _onAttemptRequested(
    DeviceSessionEvent event,
    Emitter<DeviceSessionState> emit,
  ) async {
    // One attempt at a time. A second request while one is running would only
    // race it to the same backend.
    if (state is DeviceSessionCheckingLocalCredentials ||
        state is DeviceSessionAuthenticating) {
      return;
    }
    await _attempt(emit);
  }

  Future<void> _onAutomaticRetryDue(
    _AutomaticRetryDue event,
    Emitter<DeviceSessionState> emit,
  ) async {
    // The timer only exists while unavailable, but a manual retry can have
    // moved on in between; then this tick is stale.
    if (state is! DeviceSessionAuthenticationUnavailable) return;
    await _attempt(emit);
  }

  Future<void> _attempt(Emitter<DeviceSessionState> emit) async {
    _cancelRetry();
    final generation = ++_generation;
    // Authorisation is suspended for the whole attempt: whatever JWT was held
    // is not presented again until the backend has confirmed a new one.
    _suspendDeviceAuthorization();
    emit(const DeviceSessionCheckingLocalCredentials());

    final credentialsResult = await _loadDeviceCredentials();
    if (generation != _generation) return;
    switch (credentialsResult) {
      case Err<DeviceCredentials?>(:final failure):
        _emitUnavailable(failure, emit);
      case Ok<DeviceCredentials?>(value: null):
        _unavailableStreak = 0;
        emit(const DeviceSessionNotEnrolled());
      case Ok<DeviceCredentials?>(:final value?):
        await _authenticate(value, generation, emit);
    }
  }

  Future<void> _authenticate(
    DeviceCredentials credentials,
    int generation,
    Emitter<DeviceSessionState> emit,
  ) async {
    emit(const DeviceSessionAuthenticating());

    if (!await _login(credentials, generation, emit)) return;

    final status = await _checkDeviceStatus();
    if (generation != _generation) return;
    switch (status) {
      case Ok<DeviceIdentity>(:final value):
        _emitReady(value, emit);
        return;
      case Err<DeviceIdentity>(failure: AuthFailure()):
        // The JWT minted a moment ago was not accepted. That says nothing about
        // the permanent credential — and a 401 here may not even be the
        // backend's. Only a login can answer the question, so ask it once.
        _suspendDeviceAuthorization();
      case Err<DeviceIdentity>(:final failure):
        _emitUnavailable(failure, emit);
        return;
    }

    if (!await _login(credentials, generation, emit)) return;

    final recheck = await _checkDeviceStatus();
    if (generation != _generation) return;
    switch (recheck) {
      case Ok<DeviceIdentity>(:final value):
        _emitReady(value, emit);
      case Err<DeviceIdentity>(:final failure):
        // A second refusal of a freshly renewed JWT is still not a rejection
        // of the credential. Stop here rather than loop through logins.
        _emitUnavailable(failure, emit);
    }
  }

  /// Runs the login and, unless it produced a token, emits the outcome.
  /// Returns whether the attempt should carry on to check-status.
  Future<bool> _login(
    DeviceCredentials credentials,
    int generation,
    Emitter<DeviceSessionState> emit,
  ) async {
    final login = await _authenticateDevice(credentials);
    if (generation != _generation) return false;
    switch (login) {
      case Ok<DeviceSession>():
        return true;
      case Err<DeviceSession>(failure: CredentialRejectedFailure()):
        _emitRefused(emit);
        return false;
      case Err<DeviceSession>(:final failure):
        _emitUnavailable(failure, emit);
        return false;
    }
  }

  /// Something running found out what startup could not: a renewal login was
  /// answered `401 DEVICE_CREDENTIAL_REJECTED`. The realtime layer and the
  /// REST layer only report the fact; this bloc applies it, because it owns
  /// the local installation identity.
  void _onCredentialRejected(
    DeviceSessionCredentialRejected event,
    Emitter<DeviceSessionState> emit,
  ) {
    if (state is DeviceSessionCredentialRefused ||
        state is DeviceSessionReEnrolling ||
        state is DeviceSessionNotEnrolled) {
      return;
    }
    // Supersede any attempt in flight: the rejection is the newer fact.
    _generation++;
    _emitRefused(emit);
  }

  void _onReEnrollmentRequested(
    DeviceSessionReEnrollmentRequested event,
    Emitter<DeviceSessionState> emit,
  ) {
    if (state is! DeviceSessionCredentialRefused) return;
    emit(const DeviceSessionReEnrolling());
  }

  void _onReEnrollmentCancelled(
    DeviceSessionReEnrollmentCancelled event,
    Emitter<DeviceSessionState> emit,
  ) {
    if (state is! DeviceSessionReEnrolling) return;
    emit(const DeviceSessionCredentialRefused());
  }

  void _emitReady(DeviceIdentity device, Emitter<DeviceSessionState> emit) {
    _unavailableStreak = 0;
    emit(DeviceSessionReady(device));
  }

  /// Withdraws authorisation and stops. No timer: retrying a confirmed refusal
  /// on its own would be an endless loop against a backend that already said
  /// no. The credential stays where it is.
  void _emitRefused(Emitter<DeviceSessionState> emit) {
    _cancelRetry();
    _suspendDeviceAuthorization();
    _unavailableStreak = 0;
    emit(const DeviceSessionCredentialRefused());
  }

  /// Withdraws authorisation, keeps the credential, and schedules the next
  /// attempt on the capped backoff.
  void _emitUnavailable(Failure failure, Emitter<DeviceSessionState> emit) {
    _suspendDeviceAuthorization();
    final step = _unavailableStreak < _retryBackoff.length
        ? _unavailableStreak
        : _retryBackoff.length - 1;
    _unavailableStreak++;
    _cancelRetry();
    _retryTimer = _timerFactory(
      _retryBackoff[step],
      () => add(const _AutomaticRetryDue()),
    );
    emit(DeviceSessionAuthenticationUnavailable(failure));
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  @override
  Future<void> close() {
    _cancelRetry();
    return super.close();
  }
}
