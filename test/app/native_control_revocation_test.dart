import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/app/device_realtime_coordinator.dart';
import 'package:remote_control_device/app/remote_session_coordinator.dart';
import 'package:remote_control_device/app/signaling_coordinator.dart';
import 'package:remote_control_device/app/support_coordinator.dart';
import 'package:remote_control_device/app/webrtc_coordinator.dart';
import 'package:remote_control_device/core/session/device_credential_revocation.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/check_device_status.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/device/domain/usecases/suspend_device_authorization.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_device/features/signaling/presentation/bloc/signaling/signaling_bloc.dart';
import 'package:remote_control_device/features/support/domain/usecases/accept_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/cancel_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/load_current_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/reject_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/request_support.dart';
import 'package:remote_control_device/features/support/presentation/bloc/support/support_bloc.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_device/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../fakes/device_fakes.dart';
import '../fakes/realtime_fakes.dart';
import '../fakes/remote_control_fakes.dart';
import '../fakes/remote_session_fakes.dart';
import '../fakes/screen_capture_fakes.dart';
import '../fakes/signaling_fakes.dart';
import '../fakes/support_fakes.dart';
import '../fakes/webrtc_fakes.dart';

/// Prompt 45, end to end through the real blocs and coordinators: A2 (a
/// gesture running when the authority goes) and A3 (an end that could not be
/// written, then a restart).
///
/// Only the socket, HTTP, the secure store, the peer connection, the screen
/// capture and the accessibility service are fakes. [_App] is one run of the
/// application; two runs sharing [_Outside] are a process that died and was
/// started again.
void main() {
  late _Outside outside;
  late _App app;

  setUp(() {
    outside = _Outside();
    app = _App(outside);
  });

  tearDown(() async => app.dispose());

  Future<void> settle() async {
    for (var i = 0; i < 24; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<FakeWebRtcDataChannel> reachActiveAssistance() async {
    outside.remoteSessions.currentResult = connectingRemoteSession;
    app.start();
    await settle();
    await outside.client.emit(const RealtimeConnected());
    await settle();
    await outside.client.deliver(offerReceived());
    await settle();
    final peer = outside.peers.last;
    peer.pushConnectionState(WebRtcConnectionState.connected);
    final channel = peer.pushDataChannel();
    await settle();
    channel.pushState(WebRtcDataChannelState.open);
    await settle();
    outside.remoteSessions.currentResult = activatedRemoteSession;
    await outside.client.emit(
      const RealtimeRemoteSessionActivated(testRemoteSessionId),
    );
    await settle();
    expect(app.remoteSession.state, isA<RemoteSessionActive>());
    expect(outside.accessibility.controlOpen, isTrue);
    return channel;
  }

  test('A2 end to end: a swipe running when the socket drops is cancelled on '
      'the Android side and never reported ok', () async {
    final channel = await reachActiveAssistance();
    outside.accessibility.holdGestures = true;
    channel.pushSwipe('swipe-1', durationMs: 2000);
    await settle();
    expect(outside.accessibility.swipes, hasLength(1));

    await outside.client.emit(const RealtimeServerDisconnected());
    await settle();
    expect(outside.accessibility.controlOpen, isFalse);
    // Android reports it finished all the same.
    outside.accessibility.finishGesture(RemoteGestureOutcome.completed);
    await settle();

    expect(channel.sentAcks, const [
      RemoteControlAck.failure('swipe-1', RemoteControlError.sessionNotActive),
    ]);
    // MediaProjection is kept for the recovery: a suspension is not an end.
    expect(outside.screenCapture.isActive, isTrue);
  });

  test('FINALIZAR during a swipe: gate closed and the session ended there, '
      'the swipe never ok, nothing runs afterwards', () async {
    final channel = await reachActiveAssistance();
    outside.accessibility.holdGestures = true;
    channel.pushSwipe('swipe-1', durationMs: 2000);
    await settle();

    outside.remoteSessions.currentQueue.add(noRemoteSession);
    app.remoteSession.add(const RemoteSessionCloseRequested());
    await settle();
    outside.accessibility.finishGesture(RemoteGestureOutcome.completed);
    channel.pushTap('after');
    await settle();

    expect(
      outside.accessibility.controlCalls,
      contains(('close', testRemoteSessionId)),
    );
    expect(outside.accessibility.controlOpen, isFalse);
    expect(outside.accessibility.taps, isEmpty);
    expect(channel.sentAcks.where((ack) => ack.ok), isEmpty);
    expect(outside.screenCapture.isActive, isFalse);
  });

  test('A3 end to end: FINALIZAR that cannot be written, the process dies, '
      'REST still says ACTIVE: no control, no capture, no answer', () async {
    await reachActiveAssistance();
    outside.store.failingWrites = true;
    outside.remoteSessions.closeResult = closeUnreachable;
    app.remoteSession.add(const RemoteSessionCloseRequested());
    await settle();
    expect(app.remoteSession.state, isA<RemoteSessionEndedLocally>());

    // The process dies; the storage recovers; the backend never got the close.
    await app.dispose();
    outside.store.failingWrites = false;
    outside.forNextRun();
    app = _App(outside);
    outside.remoteSessions.currentResult = activatedRemoteSession;
    app.start();
    await settle();
    await outside.client.emit(const RealtimeConnected());
    await settle();
    // The web, still in the session, offers again.
    await outside.client.deliver(offerReceived());
    await settle();

    expect(app.remoteSession.state, isNot(isA<RemoteSessionLive>()));
    expect(
      (app.remoteSession.state as RemoteSessionEndedLocally).reason,
      RemoteSessionLocalEndReason.notResumable,
    );
    expect(outside.accessibility.controlCalls, isEmpty);
    expect(outside.peers.created, isEmpty);
    expect(outside.screenCapture.requests, isEmpty);
    expect(app.signaling.state, isNot(isA<SignalingJoined>()));
  });
}

/// What outlives one run of the application: the backend, the secure store,
/// the socket and the Android side.
class _Outside {
  final FakeRemoteSessionRepository remoteSessions =
      FakeRemoteSessionRepository();
  final FakeEndedRemoteSessionStore store = FakeEndedRemoteSessionStore();
  FakeDeviceRealtimeClient client = FakeDeviceRealtimeClient();
  FakeWebRtcPeerConnectionFactory peers = FakeWebRtcPeerConnectionFactory();
  FakeScreenCaptureClient screenCapture = FakeScreenCaptureClient();
  FakeRemoteControlAccessibilityClient accessibility =
      FakeRemoteControlAccessibilityClient();

  /// A new process: a new socket, and a native side that starts empty. The
  /// backend and the secure store are the same.
  void forNextRun() {
    client = FakeDeviceRealtimeClient();
    peers = FakeWebRtcPeerConnectionFactory();
    screenCapture = FakeScreenCaptureClient();
    accessibility = FakeRemoteControlAccessibilityClient();
  }
}

class _App {
  _App(_Outside outside) {
    final storage = FakeDeviceCredentialsStorage(testCredentials);
    final tokenStore = InMemoryDeviceTokenStore();
    final authRepository = FakeDeviceAuthRepository(tokenStore: tokenStore);
    final supportRepository = FakeSupportRepository();
    final credentialRevocation = DeviceCredentialRevocation();
    final loadDeviceCredentials = LoadDeviceCredentials(storage);
    final authenticateDevice = AuthenticateDevice(authRepository);

    session = DeviceSessionBloc(
      loadDeviceCredentials: loadDeviceCredentials,
      authenticateDevice: authenticateDevice,
      checkDeviceStatus: CheckDeviceStatus(authRepository),
      suspendDeviceAuthorization: SuspendDeviceAuthorization(authRepository),
    );
    realtime = DeviceRealtimeBloc(
      client: outside.client,
      tokenStore: tokenStore,
      renewDeviceToken: RenewDeviceToken(
        loadDeviceCredentials: loadDeviceCredentials,
        authenticateDevice: authenticateDevice,
      ),
      reauthRetryDelay: const Duration(milliseconds: 20),
    );
    final support = SupportBloc(
      requestSupport: RequestSupport(supportRepository),
      loadCurrentSupportRequest: LoadCurrentSupportRequest(supportRepository),
      acceptSupportRequest: AcceptSupportRequest(supportRepository),
      rejectSupportRequest: RejectSupportRequest(supportRepository),
      cancelSupportRequest: CancelSupportRequest(supportRepository),
    );
    remoteSession = RemoteSessionBloc(
      loadCurrentRemoteSession: LoadCurrentRemoteSession(
        outside.remoteSessions,
      ),
      closeRemoteSession: CloseRemoteSession(outside.remoteSessions),
      endedSessionStore: outside.store,
    );
    signaling = SignalingBloc(client: outside.client);
    final webRtc = WebRtcSessionBloc(
      peerConnectionFactory: outside.peers,
      signaling: signaling,
      iceConfiguration: const WebRtcIceConfiguration.none(),
      screenCapture: outside.screenCapture,
      remoteControl: outside.accessibility,
    );

    final coordinators = [
      DeviceRealtimeCoordinator(
        sessionBloc: session,
        realtimeBloc: realtime,
        credentialRevocation: credentialRevocation,
      )..start(),
      SupportCoordinator(
        realtimeClient: outside.client,
        realtimeBloc: realtime,
        sessionBloc: session,
        supportBloc: support,
      )..start(),
      RemoteSessionCoordinator(
        realtimeClient: outside.client,
        realtimeBloc: realtime,
        sessionBloc: session,
        supportBloc: support,
        remoteSessionBloc: remoteSession,
      )..start(),
      SignalingCoordinator(
        realtimeBloc: realtime,
        remoteSessionBloc: remoteSession,
        signalingBloc: signaling,
      )..start(),
      WebRtcCoordinator(
        signalingBloc: signaling,
        remoteSessionBloc: remoteSession,
        webRtcBloc: webRtc,
      )..start(),
    ];

    _disposers = [
      for (final coordinator in coordinators.reversed)
        switch (coordinator) {
          final DeviceRealtimeCoordinator c => c.dispose,
          final SupportCoordinator c => c.dispose,
          final RemoteSessionCoordinator c => c.dispose,
          final SignalingCoordinator c => c.dispose,
          final WebRtcCoordinator c => c.dispose,
          _ => () async {},
        },
      credentialRevocation.dispose,
      webRtc.close,
      signaling.close,
      remoteSession.close,
      support.close,
      realtime.close,
      session.close,
    ];
  }

  late final DeviceSessionBloc session;
  late final DeviceRealtimeBloc realtime;
  late final RemoteSessionBloc remoteSession;
  late final SignalingBloc signaling;
  late final List<FutureOr<void> Function()> _disposers;
  bool _disposed = false;

  void start() {
    session.add(const DeviceSessionStarted());
    realtime.add(const DeviceRealtimeStartRequested());
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final dispose in _disposers) {
      await dispose();
    }
  }
}
