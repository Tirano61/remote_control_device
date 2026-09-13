import 'dart:async';

import 'package:remote_control_device/features/device/domain/realtime/device_realtime_client.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';
import 'package:remote_control_device/features/support/presentation/bloc/support/support_bloc.dart';

/// Turns everything that *might* have changed the support state into the one
/// thing that establishes it — a read of `GET /support-requests/current`.
///
/// ```text
/// realtime channel came up (or came back)  ──> sync
/// support:assigned arrived                 ──> sync
/// the device identity was dropped          ──> reset
/// ```
///
/// It exists so that [SupportBloc] never learns that Socket.IO exists and
/// [DeviceRealtimeBloc] never learns that support requests do. The realtime
/// signal stream is broadcast, so listening here costs the realtime bloc
/// nothing and takes nothing away from it.
///
/// Syncing on *every* arrival at connected — not only the first — is what makes
/// a missed event harmless: a tablet that was asleep while a technician took
/// its request finds out the moment its socket is back, through exactly the
/// same call as one that was awake the whole time.
class SupportCoordinator {
  SupportCoordinator({
    required DeviceRealtimeClient realtimeClient,
    required DeviceRealtimeBloc realtimeBloc,
    required DeviceSessionBloc sessionBloc,
    required SupportBloc supportBloc,
  }) : _realtimeClient = realtimeClient,
       _realtimeBloc = realtimeBloc,
       _sessionBloc = sessionBloc,
       _supportBloc = supportBloc;

  final DeviceRealtimeClient _realtimeClient;
  final DeviceRealtimeBloc _realtimeBloc;
  final DeviceSessionBloc _sessionBloc;
  final SupportBloc _supportBloc;

  StreamSubscription<DeviceRealtimeSignal>? _signalSubscription;
  StreamSubscription<DeviceRealtimeState>? _realtimeSubscription;
  StreamSubscription<DeviceSessionState>? _sessionSubscription;

  /// Whether the last observed realtime state was a live connection. The bloc
  /// re-emits `connected` when `device:connected` annotates it, and a sync per
  /// annotation would be a wasted call; only the transition into connected is
  /// news.
  bool _connected = false;

  void start() {
    _onRealtimeState(_realtimeBloc.state);
    _signalSubscription = _realtimeClient.signals.listen(_onSignal);
    _realtimeSubscription = _realtimeBloc.stream.listen(_onRealtimeState);
    _sessionSubscription = _sessionBloc.stream.listen(_onSessionState);
  }

  void _onSignal(DeviceRealtimeSignal signal) {
    if (signal is! RealtimeSupportAssigned) return;
    // The id travels on so the bloc can notice a mismatch; what the user ends
    // up seeing comes from the REST answer this triggers.
    _supportBloc.add(SupportAssignmentAnnounced(signal.supportRequestId));
  }

  void _onRealtimeState(DeviceRealtimeState state) {
    final connected = state is DeviceRealtimeConnected;
    final reconnected = connected && !_connected;
    _connected = connected;

    // A dropped connection deliberately triggers nothing: the backend does not
    // change a support request when a socket goes away, so the last known state
    // stays on screen until the backend itself says otherwise.
    if (reconnected) _supportBloc.add(const SupportSyncRequested());
  }

  void _onSessionState(DeviceSessionState state) {
    if (state is DeviceSessionReEnrollmentRequired ||
        state is DeviceSessionNotEnrolled) {
      // The request that was on screen belonged to a device identity that no
      // longer exists here. Keeping it would be showing another device's state.
      _supportBloc.add(const SupportResetRequested());
    }
  }

  Future<void> dispose() async {
    await _signalSubscription?.cancel();
    await _realtimeSubscription?.cancel();
    await _sessionSubscription?.cancel();
    _signalSubscription = null;
    _realtimeSubscription = null;
    _sessionSubscription = null;
  }
}
