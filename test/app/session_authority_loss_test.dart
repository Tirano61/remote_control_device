import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/app/device_realtime_coordinator.dart';
import 'package:remote_control_device/app/remote_session_coordinator.dart';
import 'package:remote_control_device/app/signaling_coordinator.dart';
import 'package:remote_control_device/app/support_coordinator.dart';
import 'package:remote_control_device/app/webrtc_coordinator.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/core/session/device_credential_revocation.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/check_device_status.dart';
import 'package:remote_control_device/features/device/domain/usecases/suspend_device_authorization.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_ended_by.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_capture_status.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_offer.dart';
import 'package:remote_control_device/features/signaling/presentation/bloc/signaling/signaling_bloc.dart';
import 'package:remote_control_device/features/support/domain/usecases/accept_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/cancel_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/load_current_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/reject_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/request_support.dart';
import 'package:remote_control_device/features/support/presentation/bloc/support/support_bloc.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_message.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_device/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../fakes/device_fakes.dart';
import '../fakes/manual_timers.dart';
import '../fakes/realtime_fakes.dart';
import '../fakes/remote_control_fakes.dart';
import '../fakes/remote_session_fakes.dart';
import '../fakes/screen_capture_fakes.dart';
import '../fakes/signaling_fakes.dart';
import '../fakes/support_fakes.dart';
import '../fakes/webrtc_fakes.dart';

/// C2, end to end: the tablet losing the backend's authority over a session.
/// Every bloc and coordinator is the real one; only the socket, HTTP, the
/// secure store, the native WebRTC stack, MediaProjection and the
/// accessibility service are faked, and every deadline runs on [ManualTimers].
///
/// The question: when the backend closes a session (TECHNICIAN or SYSTEM), or
/// the tablet can no longer confirm that it has not, can the technician keep
/// acting on the tablet or keep receiving its screen? Each test checks it where
/// it matters: no gesture reaches Android, the peer connection is closed, and
/// the screen is not captured.
void main() {
  late FakeDeviceRealtimeClient client;
  late FakeRemoteSessionRepository remoteSessionRepository;
  late FakeEndedRemoteSessionStore endedSessionStore;
  late FakeWebRtcPeerConnectionFactory peerFactory;
  late FakeScreenCaptureClient screenCapture;
  late FakeRemoteControlAccessibilityClient accessibility;
  late DeviceCredentialRevocation credentialRevocation;
  late ManualTimers timers;

  late DeviceSessionBloc sessionBloc;
  late DeviceRealtimeBloc realtimeBloc;
  late SupportBloc supportBloc;
  late RemoteSessionBloc remoteSessionBloc;
  late SignalingBloc signalingBloc;
  late WebRtcSessionBloc webRtcBloc;

  late List<Future<void> Function()> disposers;

  setUp(() {
    client = FakeDeviceRealtimeClient();
    final storage = FakeDeviceCredentialsStorage(testCredentials);
    final tokenStore = InMemoryDeviceTokenStore();
    final authRepository = FakeDeviceAuthRepository(tokenStore: tokenStore);
    final supportRepository = FakeSupportRepository();
    remoteSessionRepository = FakeRemoteSessionRepository();
    endedSessionStore = FakeEndedRemoteSessionStore();
    peerFactory = FakeWebRtcPeerConnectionFactory();
    screenCapture = FakeScreenCaptureClient();
    accessibility = FakeRemoteControlAccessibilityClient();
    credentialRevocation = DeviceCredentialRevocation();
    timers = ManualTimers();

    final loadDeviceCredentials = LoadDeviceCredentials(storage);
    final authenticateDevice = AuthenticateDevice(authRepository);

    sessionBloc = DeviceSessionBloc(
      loadDeviceCredentials: loadDeviceCredentials,
      authenticateDevice: authenticateDevice,
      checkDeviceStatus: CheckDeviceStatus(authRepository),
      suspendDeviceAuthorization: SuspendDeviceAuthorization(authRepository),
    );
    realtimeBloc = DeviceRealtimeBloc(
      client: client,
      tokenStore: tokenStore,
      renewDeviceToken: RenewDeviceToken(
        loadDeviceCredentials: loadDeviceCredentials,
        authenticateDevice: authenticateDevice,
      ),
      reauthRetryDelay: const Duration(milliseconds: 20),
    );
    supportBloc = SupportBloc(
      requestSupport: RequestSupport(supportRepository),
      loadCurrentSupportRequest: LoadCurrentSupportRequest(supportRepository),
      acceptSupportRequest: AcceptSupportRequest(supportRepository),
      rejectSupportRequest: RejectSupportRequest(supportRepository),
      cancelSupportRequest: CancelSupportRequest(supportRepository),
    );
    remoteSessionBloc = RemoteSessionBloc(
      loadCurrentRemoteSession: LoadCurrentRemoteSession(
        remoteSessionRepository,
      ),
      closeRemoteSession: CloseRemoteSession(remoteSessionRepository),
      endedSessionStore: endedSessionStore,
      timerFactory: timers.factory,
    );
    signalingBloc = SignalingBloc(client: client);
    webRtcBloc = WebRtcSessionBloc(
      peerConnectionFactory: peerFactory,
      signaling: signalingBloc,
      iceConfiguration: const WebRtcIceConfiguration.none(),
      screenCapture: screenCapture,
      remoteControl: accessibility,
      timerFactory: timers.factory,
    );

    final realtimeCoordinator = DeviceRealtimeCoordinator(
      sessionBloc: sessionBloc,
      realtimeBloc: realtimeBloc,
      credentialRevocation: credentialRevocation,
    )..start();
    final supportCoordinator = SupportCoordinator(
      realtimeClient: client,
      realtimeBloc: realtimeBloc,
      sessionBloc: sessionBloc,
      supportBloc: supportBloc,
    )..start();
    final remoteSessionCoordinator = RemoteSessionCoordinator(
      realtimeClient: client,
      realtimeBloc: realtimeBloc,
      sessionBloc: sessionBloc,
      supportBloc: supportBloc,
      remoteSessionBloc: remoteSessionBloc,
    )..start();
    final signalingCoordinator = SignalingCoordinator(
      realtimeBloc: realtimeBloc,
      remoteSessionBloc: remoteSessionBloc,
      signalingBloc: signalingBloc,
    )..start();
    final webRtcCoordinator = WebRtcCoordinator(
      signalingBloc: signalingBloc,
      remoteSessionBloc: remoteSessionBloc,
      webRtcBloc: webRtcBloc,
    )..start();

    disposers = [
      webRtcCoordinator.dispose,
      signalingCoordinator.dispose,
      remoteSessionCoordinator.dispose,
      supportCoordinator.dispose,
      realtimeCoordinator.dispose,
      credentialRevocation.dispose,
      webRtcBloc.close,
      signalingBloc.close,
      remoteSessionBloc.close,
      supportBloc.close,
      realtimeBloc.close,
      sessionBloc.close,
    ];
  });

  tearDown(() async {
    for (final dispose in disposers) {
      await dispose();
    }
  });

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// An assistance in full swing: authenticated, socket up, signaling joined,
  /// peer connected, control channel open, screen shared, session ACTIVE.
  Future<(FakeWebRtcPeerConnection, FakeWebRtcDataChannel)>
  reachActiveAssistance() async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    sessionBloc.add(const DeviceSessionStarted());
    await settle();
    realtimeBloc.add(const DeviceRealtimeStartRequested());
    await settle();
    await client.emit(const RealtimeConnected());
    await settle();

    await client.deliver(offerReceived());
    await settle();
    final peer = peerFactory.last;
    peer.pushConnectionState(WebRtcConnectionState.connected);
    final channel = peer.pushDataChannel();
    await settle();
    channel.pushState(WebRtcDataChannelState.open);
    await settle();

    remoteSessionRepository.currentResult = activatedRemoteSession;
    await client.emit(
      const RealtimeRemoteSessionActivated(testRemoteSessionId),
    );
    await settle();

    expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
    expect(webRtcBloc.state.isRemoteConnectionEstablished, isTrue);
    expect(screenCapture.isActive, isTrue);
    // Control works before FINALIZAR, so its absence afterwards means
    // something.
    channel.pushTap('before');
    await settle();
    expect(accessibility.taps, [(0.5, 0.5)]);
    return (peer, channel);
  }

  /// Everything a technician could still use is gone.
  void expectNothingLeft(
    FakeWebRtcPeerConnection peer,
    FakeWebRtcDataChannel channel,
  ) {
    expect(peer.isClosed, isTrue);
    expect(channel.isClosed, isTrue);
    expect(screenCapture.isActive, isFalse);
    expect(screenCapture.stopCount, greaterThanOrEqualTo(1));
    expect(webRtcBloc.state, const WebRtcIdle());
    expect(signalingBloc.state, const SignalingIdle());
  }

  void pushHold(FakeWebRtcDataChannel channel) => channel.pushFrame(
    const WebRtcDataChannelMessage.text(
      '{"v":1,"type":"touch_hold","id":"hold-1","touch":"t-1",'
      '"x":0.41,"y":0.52}',
    ),
  );

  const grace = RemoteSessionBloc.defaultAuthorityGracePeriod;

  /// Control obeys right now: a tap reaches Android.
  Future<bool> tapRuns(FakeWebRtcDataChannel channel, String id) async {
    final before = accessibility.taps.length;
    channel.pushTap(id);
    await settle();
    return accessibility.taps.length > before;
  }

  /// A DRAG in progress: the finger is down on the Android side.
  Future<int> holdFinger(FakeWebRtcDataChannel channel) async {
    pushHold(channel);
    await settle();
    accessibility.answerStart();
    await settle();
    return (accessibility.touchCalls.last as (String, int, double, double)).$2;
  }

  /// Let go, never dropped: abandoned, and no release ever sent.
  void expectAbandoned(int handle) {
    expect(accessibility.touchCalls, contains(('abandon', handle)));
    expect(
      accessibility.touchCalls.whereType<(String, int, int, double, double)>(),
      isEmpty,
    );
  }

  Future<void> dropSocket() async {
    await client.emit(const RealtimeDisconnected());
    await settle();
  }

  Future<void> restoreSocket() async {
    await client.emit(const RealtimeConnected());
    await settle();
  }

  group('1-2. remote-session:closed', () {
    test(
      'SYSTEM: control, peer, channel and screen go before REST answers',
      () async {
        final (peer, channel) = await reachActiveAssistance();
        final gate = remoteSessionRepository.currentGate = Completer<void>();
        remoteSessionRepository.currentResult = noRemoteSession;
        late final bool peerClosedBeforeCapture;
        screenCapture.onStop = () => peerClosedBeforeCapture = peer.isClosed;

        await client.emit(
          const RealtimeRemoteSessionClosed(
            testRemoteSessionId,
            endedBy: 'SYSTEM',
          ),
        );
        await settle();

        // The read has not answered and everything is already gone.
        expect(remoteSessionBloc.state, isA<RemoteSessionClosedRemotely>());
        expectNothingLeft(peer, channel);
        expect(peerClosedBeforeCapture, isTrue);
        expect(await tapRuns(channel, 'after'), isFalse);

        gate.complete();
        await settle();
        expect(
          remoteSessionBloc.state,
          const RemoteSessionIdle(lastClosure: RemoteSessionEndedBy.system),
        );
        expectNothingLeft(peer, channel);
      },
    );

    test('during a DRAG: the finger is abandoned, never dropped', () async {
      final (peer, channel) = await reachActiveAssistance();
      final handle = await holdFinger(channel);
      remoteSessionRepository.currentResult = noRemoteSession;

      await client.emit(
        const RealtimeRemoteSessionClosed(
          testRemoteSessionId,
          endedBy: 'SYSTEM',
        ),
      );
      await settle();

      expectAbandoned(handle);
      final calls = accessibility.touchCalls.length;
      // A release or a new hold after the close reaches nothing.
      channel.pushFrame(
        const WebRtcDataChannelMessage.text(
          '{"v":1,"type":"touch_release","id":"rel-2","touch":"t-1",'
          '"seq":2,"x":0.6,"y":0.7}',
        ),
      );
      pushHold(channel);
      await settle();
      expect(accessibility.touchCalls, hasLength(calls));
      expectNothingLeft(peer, channel);
    });
  });

  group('3-6. socket lost while WebRTC stays up', () {
    test('control is suspended at once; peer and screen are kept', () async {
      final (peer, channel) = await reachActiveAssistance();

      await dropSocket();

      expect(await tapRuns(channel, 'while-down'), isFalse);
      expect(
        channel.sentAcks.last,
        const RemoteControlAck.failure(
          'while-down',
          RemoteControlError.sessionNotActive,
        ),
      );
      expect(peer.isClosed, isFalse);
      expect(channel.isClosed, isFalse);
      expect(screenCapture.isActive, isTrue);
      expect(webRtcBloc.state.isRemoteConnectionEstablished, isTrue);
    });

    test('a DRAG is abandoned when the socket drops', () async {
      final (_, channel) = await reachActiveAssistance();
      final handle = await holdFinger(channel);

      await dropSocket();

      expectAbandoned(handle);
    });

    test('back within the window: control returns only after REST confirms, '
        'and nothing sent meanwhile runs', () async {
      final (peer, channel) = await reachActiveAssistance();
      await dropSocket();
      channel.pushTap('sent-while-down');
      await settle();
      timers.elapse(grace - const Duration(seconds: 5));
      await settle();

      final gate = remoteSessionRepository.currentGate = Completer<void>();
      await restoreSocket();
      // Connected again, but not reconciled yet.
      expect(await tapRuns(channel, 'before-rest'), isFalse);

      gate.complete();
      await settle();
      expect(await tapRuns(channel, 'after-rest'), isTrue);
      // Exactly two taps: the one before the drop and the one after REST.
      expect(accessibility.taps, hasLength(2));
      expect(peer.isClosed, isFalse);
      expect(peerFactory.createCount, 1);
      timers.elapse(grace * 2);
      await settle();
      expect(screenCapture.isActive, isTrue);
    });

    test('back after the window: ended here, and the backend still saying '
        'ACTIVE gets the close again', () async {
      final (peer, channel) = await reachActiveAssistance();
      remoteSessionRepository.closeResult = closeUnreachable;
      await dropSocket();

      timers.elapse(grace);
      await settle();

      final ended = remoteSessionBloc.state as RemoteSessionEndedLocally;
      expect(ended.reason, RemoteSessionLocalEndReason.authorityLost);
      expectNothingLeft(peer, channel);
      expect(endedSessionStore.value, testRemoteSessionId);

      remoteSessionRepository.closeResult = const Ok(closedSession);
      remoteSessionRepository.currentQueue.add(activatedRemoteSession);
      remoteSessionRepository.currentResult = noRemoteSession;
      final joins = client.joinedSessionIds.length;
      await restoreSocket();

      expect(remoteSessionRepository.closeCount, 2);
      expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
      expect(client.joinedSessionIds, hasLength(joins));
      expect(screenCapture.requests, [testRemoteSessionId]);
      expectNothingLeft(peer, channel);
    });
  });

  group('7-10. reconciliation over REST', () {
    test('null on return: the session is over, everything goes', () async {
      final (peer, channel) = await reachActiveAssistance();
      await dropSocket();
      remoteSessionRepository.currentResult = noRemoteSession;

      await restoreSocket();

      expect(
        remoteSessionBloc.state,
        const RemoteSessionIdle(lastClosure: RemoteSessionEndedBy.unknown),
      );
      expectNothingLeft(peer, channel);
      expect(remoteSessionRepository.closeCount, 0);
    });

    test('ACTIVE for a session already revoked here resumes nothing', () async {
      final (peer, channel) = await reachActiveAssistance();
      remoteSessionRepository.closeResult = closeUnreachable;
      await dropSocket();
      timers.elapse(grace);
      await settle();

      // The backend never heard; it still says ACTIVE.
      await restoreSocket();

      expect(remoteSessionBloc.state, isA<RemoteSessionEndedLocally>());
      expect(await tapRuns(channel, 'after'), isFalse);
      expectNothingLeft(peer, channel);
    });

    test(
      'a failing REST keeps control suspended until the window closes it',
      () async {
        final (peer, channel) = await reachActiveAssistance();
        remoteSessionRepository.closeResult = closeUnreachable;
        await dropSocket();
        remoteSessionRepository.currentResult = remoteSessionUnreachable;
        await restoreSocket();

        expect(await tapRuns(channel, 'rest-down'), isFalse);
        expect(peer.isClosed, isFalse);

        timers.elapse(grace);
        await settle();
        expect(remoteSessionBloc.state, isA<RemoteSessionEndedLocally>());
        expectNothingLeft(peer, channel);
      },
    );

    test(
      'a GET that answers ACTIVE after the CLOSED event restores nothing',
      () async {
        final (peer, channel) = await reachActiveAssistance();
        final gate = remoteSessionRepository.currentGate = Completer<void>();
        // A read is under way: the backend answered ACTIVE before it closed.
        remoteSessionBloc.add(const RemoteSessionSyncRequested());
        await settle();

        await client.emit(
          const RealtimeRemoteSessionClosed(
            testRemoteSessionId,
            endedBy: 'SYSTEM',
          ),
        );
        await settle();
        gate.complete();
        await settle();

        expect(remoteSessionBloc.state, isA<RemoteSessionClosedRemotely>());
        expect(await tapRuns(channel, 'after'), isFalse);
        expectNothingLeft(peer, channel);
      },
    );
  });

  test('13. MediaProjection onStop: control and peer go; nothing restarts '
      'the screen', () async {
    final (peer, channel) = await reachActiveAssistance();
    final handle = await holdFinger(channel);

    screenCapture.endFromPlatform();
    await settle();

    expectAbandoned(handle);
    expect(peer.isClosed, isTrue);
    expect(channel.isClosed, isTrue);
    expect(webRtcBloc.state.screenCapture, ScreenCaptureStatus.stoppedBySystem);
    // The assistance itself is still the user's (or the technician's) to end.
    expect(remoteSessionBloc.state, isA<RemoteSessionActive>());

    await client.deliver(offerReceived(sdp: testSecondOfferSdp));
    await settle();
    expect(peerFactory.createCount, 1);
    expect(screenCapture.requests, [testRemoteSessionId]);
  });

  group('14-15. leftovers from a revoked session', () {
    test('an old offer builds nothing', () async {
      final (peer, channel) = await reachActiveAssistance();
      remoteSessionRepository.currentResult = noRemoteSession;
      await client.emit(const RealtimeRemoteSessionClosed(testRemoteSessionId));
      await settle();

      await client.deliver(offerReceived(sdp: testSecondOfferSdp));
      webRtcBloc.add(
        const WebRtcOfferReceived(
          WebRtcOffer(remoteSessionId: testRemoteSessionId, sdp: testSdp),
        ),
      );
      await settle();

      expect(peerFactory.createCount, 1);
      expect(screenCapture.requests, [testRemoteSessionId]);
      expectNothingLeft(peer, channel);
    });

    test(
      'a data channel of the old peer is closed, and delivers nothing',
      () async {
        final (peer, channel) = await reachActiveAssistance();
        remoteSessionRepository.currentResult = noRemoteSession;
        await client.emit(
          const RealtimeRemoteSessionClosed(testRemoteSessionId),
        );
        await settle();

        final reopened = FakeWebRtcDataChannel(
          label: 'control',
          initialState: WebRtcDataChannelState.open,
        );
        for (var generation = 0; generation < 6; generation++) {
          webRtcBloc.add(WebRtcDataChannelOffered(generation, reopened));
        }
        await settle();
        reopened.pushTap('via-reopened');
        channel.pushTap('via-old');
        await settle();

        expect(reopened.isClosed, isTrue);
        expect(accessibility.taps, hasLength(1));
        expectNothingLeft(peer, channel);
      },
    );
  });

  test('18. closures repeated by every route are idempotent', () async {
    final (peer, channel) = await reachActiveAssistance();
    remoteSessionRepository.currentResult = noRemoteSession;

    for (var i = 0; i < 3; i++) {
      await client.emit(
        const RealtimeRemoteSessionClosed(
          testRemoteSessionId,
          endedBy: 'SYSTEM',
        ),
      );
    }
    await settle();
    await dropSocket();
    timers.elapse(grace * 3);
    await restoreSocket();

    expect(peer.closeCount, 1);
    expect(channel.closeCount, 1);
    expect(remoteSessionRepository.closeCount, 0);
    expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
    expectNothingLeft(peer, channel);
  });

  test('19. a new, legitimate assistance starts through its own consent and '
      'its own confirmation', () async {
    final (peer, channel) = await reachActiveAssistance();
    remoteSessionRepository.currentResult = noRemoteSession;
    await client.emit(
      const RealtimeRemoteSessionClosed(testRemoteSessionId, endedBy: 'SYSTEM'),
    );
    await settle();
    expectNothingLeft(peer, channel);

    remoteSessionRepository.currentResult = const Ok<RemoteSession?>(
      RemoteSession(
        id: testOtherRemoteSessionId,
        supportRequestId: testSupportRequestId,
        status: RemoteSessionStatus.connecting,
        technician: testRemoteSessionTechnician,
      ),
    );
    await client.emit(
      const RealtimeRemoteSessionCreated(
        remoteSessionId: testOtherRemoteSessionId,
        supportRequestId: testSupportRequestId,
        technicianId: testTechnicianId,
      ),
    );
    await settle();
    await client.deliver(
      offerReceived(remoteSessionId: testOtherRemoteSessionId),
    );
    await settle();
    final newPeer = peerFactory.last;
    newPeer.pushConnectionState(WebRtcConnectionState.connected);
    final newChannel = newPeer.pushDataChannel();
    await settle();
    newChannel.pushState(WebRtcDataChannelState.open);
    await settle();

    expect(peerFactory.createCount, 2);
    expect(screenCapture.requests, [
      testRemoteSessionId,
      testOtherRemoteSessionId,
    ]);
    // CONNECTING: not yet authorised to obey.
    expect(await tapRuns(newChannel, 'connecting'), isFalse);

    remoteSessionRepository.currentResult = const Ok<RemoteSession?>(
      RemoteSession(
        id: testOtherRemoteSessionId,
        supportRequestId: testSupportRequestId,
        status: RemoteSessionStatus.active,
        technician: testRemoteSessionTechnician,
      ),
    );
    await client.emit(
      const RealtimeRemoteSessionActivated(testOtherRemoteSessionId),
    );
    await settle();
    expect(await tapRuns(newChannel, 'active'), isTrue);
  });
}
