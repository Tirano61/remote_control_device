import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/device/domain/entities/device_credentials.dart';
import 'package:remote_control_device/features/device/domain/entities/device_identity.dart';
import 'package:remote_control_device/features/device/domain/entities/device_session.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/check_device_status.dart';
import 'package:remote_control_device/features/device/domain/usecases/clear_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';

part 'device_session_event.dart';
part 'device_session_state.dart';

/// Owns the startup decision:
///
/// ```text
/// local credentials? ──no──> notEnrolled
///        │yes
///        ↓
/// POST /device-auth/login
///        │
///        ├── 401 ─────────> wipe credentials ──> reEnrollmentRequired
///        ├── network/5xx ─> keep credentials ──> networkError (retryable)
///        ↓ ok
/// GET /device-auth/check-status
///        ├── 401 ─────────> wipe credentials ──> reEnrollmentRequired
///        ├── network/5xx ─> keep credentials ──> networkError (retryable)
///        ↓ ok
///      ready
/// ```
///
/// The backend is authoritative: a cached credential alone never puts the app
/// in [DeviceSessionReady].
class DeviceSessionBloc extends Bloc<DeviceSessionEvent, DeviceSessionState> {
  DeviceSessionBloc({
    required LoadDeviceCredentials loadDeviceCredentials,
    required AuthenticateDevice authenticateDevice,
    required CheckDeviceStatus checkDeviceStatus,
    required ClearDeviceCredentials clearDeviceCredentials,
  }) : _loadDeviceCredentials = loadDeviceCredentials,
       _authenticateDevice = authenticateDevice,
       _checkDeviceStatus = checkDeviceStatus,
       _clearDeviceCredentials = clearDeviceCredentials,
       super(const DeviceSessionInitial()) {
    on<DeviceSessionStarted>(_onStartupRequested);
    on<DeviceSessionRetryRequested>(_onStartupRequested);
    on<DeviceSessionEnrollmentCompleted>(_onStartupRequested);
  }

  final LoadDeviceCredentials _loadDeviceCredentials;
  final AuthenticateDevice _authenticateDevice;
  final CheckDeviceStatus _checkDeviceStatus;
  final ClearDeviceCredentials _clearDeviceCredentials;

  Future<void> _onStartupRequested(
    DeviceSessionEvent event,
    Emitter<DeviceSessionState> emit,
  ) async {
    emit(const DeviceSessionCheckingLocalCredentials());

    final credentialsResult = await _loadDeviceCredentials();
    switch (credentialsResult) {
      case Err<DeviceCredentials?>(:final failure):
        emit(DeviceSessionNetworkError(failure));
        return;
      case Ok<DeviceCredentials?>(value: null):
        emit(const DeviceSessionNotEnrolled());
        return;
      case Ok<DeviceCredentials?>(:final value?):
        await _authenticate(value, emit);
    }
  }

  Future<void> _authenticate(
    DeviceCredentials credentials,
    Emitter<DeviceSessionState> emit,
  ) async {
    emit(const DeviceSessionAuthenticating());

    final loginResult = await _authenticateDevice(credentials);
    if (loginResult case Err<DeviceSession>(:final failure)) {
      await _emitFailure(failure, emit);
      return;
    }

    final statusResult = await _checkDeviceStatus();
    switch (statusResult) {
      case Ok<DeviceIdentity>(:final value):
        emit(DeviceSessionReady(value));
      case Err<DeviceIdentity>(:final failure):
        await _emitFailure(failure, emit);
    }
  }

  /// Only an outright rejection by the backend destroys the local credential.
  /// Anything else is treated as temporary and stays retryable.
  Future<void> _emitFailure(
    Failure failure,
    Emitter<DeviceSessionState> emit,
  ) async {
    if (failure is AuthFailure) {
      await _clearDeviceCredentials();
      emit(const DeviceSessionReEnrollmentRequired());
      return;
    }
    emit(DeviceSessionNetworkError(failure));
  }
}
