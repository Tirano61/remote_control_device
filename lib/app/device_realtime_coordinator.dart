import 'dart:async';

import 'package:remote_control_device/core/session/device_credential_revocation.dart';
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
/// anything says the permanent credential was rejected
///                           ──> the session wipes it and requires enrollment
/// ```
///
/// The channel is therefore never opened before a login, during enrollment, or
/// while re-enrollment is required — the states in which there is no Device JWT
/// worth presenting.
///
/// "Anything" is meant literally. The socket is no longer the only thing that
/// can discover a revoked credential: an authenticated REST call that gets a
/// `401` re-authenticates too, and can be refused too. Both report through
/// [DeviceCredentialRevocation] and arrive here, so there is one place in the
/// application that decides what a revoked credential costs — and one only.
class DeviceRealtimeCoordinator {
  DeviceRealtimeCoordinator({
    required DeviceSessionBloc sessionBloc,
    required DeviceRealtimeBloc realtimeBloc,
    required DeviceCredentialRevocation credentialRevocation,
  }) : _sessionBloc = sessionBloc,
       _realtimeBloc = realtimeBloc,
       _credentialRevocation = credentialRevocation;

  final DeviceSessionBloc _sessionBloc;
  final DeviceRealtimeBloc _realtimeBloc;
  final DeviceCredentialRevocation _credentialRevocation;

  StreamSubscription<DeviceSessionState>? _sessionSubscription;
  StreamSubscription<DeviceRealtimeState>? _realtimeSubscription;
  StreamSubscription<void>? _revocationSubscription;

  void start() {
    // The current state counts, not only future transitions: the session may
    // already be READY by the time the coordinator is wired up.
    _onSessionState(_sessionBloc.state);
    _sessionSubscription = _sessionBloc.stream.listen(_onSessionState);
    _realtimeSubscription = _realtimeBloc.stream.listen(_onRealtimeState);
    _revocationSubscription = _credentialRevocation.revocations.listen(
      (_) => _reportCredentialRejected(),
    );
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
      _reportCredentialRejected();
    }
  }

  void _reportCredentialRejected() =>
      _sessionBloc.add(const DeviceSessionCredentialRejected());

  Future<void> dispose() async {
    await _sessionSubscription?.cancel();
    await _realtimeSubscription?.cancel();
    await _revocationSubscription?.cancel();
    _sessionSubscription = null;
    _realtimeSubscription = null;
    _revocationSubscription = null;
  }
}
