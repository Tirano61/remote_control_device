import 'dart:async';

import 'package:remote_control_device/features/device/domain/realtime/device_realtime_client.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_device/features/support/presentation/bloc/support/support_bloc.dart';

/// Turns everything that *might* have changed the remote session into the one
/// thing that establishes it — a read of `GET /device/remote-sessions/current`.
///
/// ```text
/// realtime channel came up (or came back) ──> sync
/// remote-session:created arrived          ──> sync
/// remote-session:active arrived           ──> sync, if it is the session held
/// remote-session:closed arrived           ──> sync
/// the support request reached ACCEPTED    ──> sync
/// the device identity was dropped         ──> reset
///
/// a live session stopped being live       ──> re-read the support request
/// ```
///
/// `remote-session:active` is the one cue with a condition attached, and the
/// condition is the bloc's to apply — this class forwards the id and decides
/// nothing. The device never calls `POST /remote-sessions/:id/activate`: the
/// transition belongs to `remote_control_web`, and the tablet only reads what
/// the backend wrote.
///
/// The last line is the only arrow that points the other way, and it exists
/// because one backend transaction writes both sides: closing a session — from
/// either end — completes its support request. Learning that the session is
/// gone therefore means the request on screen is stale too.
///
/// Nothing here lets the blocs see each other. [RemoteSessionBloc] never learns
/// that Socket.IO exists, [SupportBloc] never learns that remote sessions do,
/// and [DeviceRealtimeBloc] knows about neither.
///
/// Syncing on *every* arrival at connected — not only the first — is what makes
/// a missed `remote-session:created` harmless: a tablet that was asleep while
/// the technician pressed "start" finds the session the moment its socket is
/// back, through exactly the same call as one that was awake the whole time.
/// It is also the whole restart story: a fresh application reaches connected
/// once, and that first arrival recovers a session created before it launched.
class RemoteSessionCoordinator {
  RemoteSessionCoordinator({
    required DeviceRealtimeClient realtimeClient,
    required DeviceRealtimeBloc realtimeBloc,
    required DeviceSessionBloc sessionBloc,
    required SupportBloc supportBloc,
    required RemoteSessionBloc remoteSessionBloc,
  }) : _realtimeClient = realtimeClient,
       _realtimeBloc = realtimeBloc,
       _sessionBloc = sessionBloc,
       _supportBloc = supportBloc,
       _remoteSessionBloc = remoteSessionBloc;

  final DeviceRealtimeClient _realtimeClient;
  final DeviceRealtimeBloc _realtimeBloc;
  final DeviceSessionBloc _sessionBloc;
  final SupportBloc _supportBloc;
  final RemoteSessionBloc _remoteSessionBloc;

  StreamSubscription<DeviceRealtimeSignal>? _signalSubscription;
  StreamSubscription<DeviceRealtimeState>? _realtimeSubscription;
  StreamSubscription<DeviceSessionState>? _sessionSubscription;
  StreamSubscription<SupportState>? _supportSubscription;
  StreamSubscription<RemoteSessionState>? _remoteSessionSubscription;

  /// Whether the last observed realtime state was a live connection. Only the
  /// transition into connected is news; the bloc re-emits `connected` when
  /// `device:connected` annotates it, and a sync per annotation would be a
  /// wasted call.
  bool _connected = false;

  /// Whether the support request was already `ACCEPTED` when last seen. The
  /// state is re-emitted for every `busy` and `lastFailure` change, and only
  /// the moment the user authorises the technician is worth a read.
  bool _accepted = false;

  /// Whether a live session was held when last seen. Its disappearance is what
  /// makes the support request worth re-reading.
  bool _live = false;

  void start() {
    _onRealtimeState(_realtimeBloc.state);
    _onSupportState(_supportBloc.state);
    _signalSubscription = _realtimeClient.signals.listen(_onSignal);
    _realtimeSubscription = _realtimeBloc.stream.listen(_onRealtimeState);
    _sessionSubscription = _sessionBloc.stream.listen(_onSessionState);
    _supportSubscription = _supportBloc.stream.listen(_onSupportState);
    _remoteSessionSubscription = _remoteSessionBloc.stream.listen(
      _onRemoteSessionState,
    );
  }

  void _onSignal(DeviceRealtimeSignal signal) {
    // The ids travel on so the bloc can notice a mismatch and log it; what the
    // user ends up seeing comes from the REST read these trigger.
    switch (signal) {
      case RealtimeRemoteSessionCreated(:final remoteSessionId):
        _remoteSessionBloc.add(RemoteSessionAnnounced(remoteSessionId));
      case RealtimeRemoteSessionActivated(:final remoteSessionId):
        // The technician's `/activate` committed. Which session it was about
        // is carried through so the bloc can match it against the one it holds;
        // whether that means anything is the bloc's decision, and what the user
        // ends up seeing is the REST read it makes.
        _remoteSessionBloc.add(
          RemoteSessionActivationAnnounced(remoteSessionId),
        );
      case RealtimeRemoteSessionClosed(:final remoteSessionId):
        _remoteSessionBloc.add(RemoteSessionClosureAnnounced(remoteSessionId));
      default:
        return;
    }
  }

  void _onRealtimeState(DeviceRealtimeState state) {
    final connected = state is DeviceRealtimeConnected;
    final reconnected = connected && !_connected;
    _connected = connected;

    // A dropped connection deliberately triggers nothing. The backend does not
    // end a session because a socket went away, so the last known state stays
    // on screen — the panel says "reconnecting", not "the assistance ended".
    if (reconnected) {
      _remoteSessionBloc.add(const RemoteSessionSyncRequested());
    }
  }

  void _onSupportState(SupportState state) {
    final accepted = state is SupportAccepted;
    final justAccepted = accepted && !_accepted;
    _accepted = accepted;

    // `ACCEPTED` is what authorises a session to exist. There will usually not
    // be one yet — the technician has still to press "start" — and an empty
    // answer is the expected one, not a failure.
    if (justAccepted) {
      _remoteSessionBloc.add(const RemoteSessionSyncRequested());
    }
  }

  void _onRemoteSessionState(RemoteSessionState state) {
    final live = state is RemoteSessionLive;
    // A reset is the one way to stop being live without the backend having said
    // anything, and it happens precisely when the device identity is gone. Then
    // there is nothing left to ask with, and the support state has just been
    // cleared for the same reason — re-reading it would only undo that.
    final ended = _live && !live && state is! RemoteSessionInitial;
    _live = live;

    // Otherwise: the session and its request are closed in one backend
    // transaction, so a session that is gone means a request that is
    // `COMPLETED`. Without this the screen would fall back to a request the
    // backend has already finished.
    if (ended) _supportBloc.add(const SupportSyncRequested());
  }

  void _onSessionState(DeviceSessionState state) {
    if (state is DeviceSessionReEnrollmentRequired ||
        state is DeviceSessionNotEnrolled) {
      // The session on screen belonged to a device identity that no longer
      // exists here. A remote assistance session must never outlive the
      // credential that authorised it.
      _remoteSessionBloc.add(const RemoteSessionResetRequested());
    }
  }

  Future<void> dispose() async {
    await _signalSubscription?.cancel();
    await _realtimeSubscription?.cancel();
    await _sessionSubscription?.cancel();
    await _supportSubscription?.cancel();
    await _remoteSessionSubscription?.cancel();
    _signalSubscription = null;
    _realtimeSubscription = null;
    _sessionSubscription = null;
    _supportSubscription = null;
    _remoteSessionSubscription = null;
  }
}
