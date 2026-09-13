import 'dart:async';

import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';

/// Keeps the realtime channel and the device session in step without letting
/// either bloc know the other exists.
///
/// The rule in each direction is one sentence:
///
/// ```text
/// session is READY          ──> open the realtime channel
/// session is anything else  ──> release it
/// realtime says the permanent credential was rejected
///                           ──> the session wipes it and requires enrollment
/// ```
///
/// The channel is therefore never opened before a login, during enrollment, or
/// while re-enrollment is required — the states in which there is no Device JWT
/// worth presenting.
class DeviceRealtimeCoordinator {
  DeviceRealtimeCoordinator({
    required DeviceSessionBloc sessionBloc,
    required DeviceRealtimeBloc realtimeBloc,
  }) : _sessionBloc = sessionBloc,
       _realtimeBloc = realtimeBloc;

  final DeviceSessionBloc _sessionBloc;
  final DeviceRealtimeBloc _realtimeBloc;

  StreamSubscription<DeviceSessionState>? _sessionSubscription;
  StreamSubscription<DeviceRealtimeState>? _realtimeSubscription;

  void start() {
    // The current state counts, not only future transitions: the session may
    // already be READY by the time the coordinator is wired up.
    _onSessionState(_sessionBloc.state);
    _sessionSubscription = _sessionBloc.stream.listen(_onSessionState);
    _realtimeSubscription = _realtimeBloc.stream.listen(_onRealtimeState);
  }

  void _onSessionState(DeviceSessionState state) {
    _realtimeBloc.add(
      state is DeviceSessionReady
          ? const DeviceRealtimeStartRequested()
          : const DeviceRealtimeStopRequested(),
    );
  }

  void _onRealtimeState(DeviceRealtimeState state) {
    if (state is DeviceRealtimeDisconnected &&
        state.cause == DeviceRealtimeStopCause.credentialRejected) {
      _sessionBloc.add(const DeviceSessionCredentialRejected());
    }
  }

  Future<void> dispose() async {
    await _sessionSubscription?.cancel();
    await _realtimeSubscription?.cancel();
    _sessionSubscription = null;
    _realtimeSubscription = null;
  }
}
