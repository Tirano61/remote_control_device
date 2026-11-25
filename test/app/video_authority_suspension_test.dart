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
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_capture_status.dart';
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

/// Prompt 40 (B3), end to end: the screen while the tablet cannot confirm the
/// session's authority. Every bloc and coordinator is the real one; the native
/// pieces are faked, MediaProjection by [FakeScreenCaptureClient], which counts
/// what a receiving console would count: a frame per screen change while the
/// capture transmits, none while it is held back.
///
/// Capturing and transmitting are kept apart throughout: a suspension must keep
/// every new frame on the tablet while the capture, its consent and the peer
/// stay for the recovery.
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

  // --------------------------------------------------------------- Prompt 40

  /// The screen changes [times] times. Each change is a frame the technician
  /// receives only while the capture is transmitting.
  void screenChanges([int times = 3]) {
    for (var i = 0; i < times; i++) {
      screenCapture.screenChanged();
    }
  }

  /// Whether the tablet can vouch for the live session right now.
  bool authorityConfirmed() {
    final state = remoteSessionBloc.state;
    return state is RemoteSessionLive &&
        state.authority == RemoteSessionAuthority.confirmed;
  }

  /// The invariant this prompt is about, checked at a point in a scenario:
  /// the screen reaches the technician exactly when the session is confirmed.
  void expectTransmissionFollowsAuthority() {
    expect(
      screenCapture.transmitting,
      screenCapture.isActive && authorityConfirmed(),
      reason: 'state: ${remoteSessionBloc.state}',
    );
  }

  /// Nothing reopened the screen after [from] entries of the record.
  void expectNeverReopenedAfter(int from) {
    expect(
      screenCapture.transmissions.skip(from).where((t) => t.$2),
      isEmpty,
    );
  }

  Future<void> finalizar() async {
    remoteSessionBloc.add(const RemoteSessionCloseRequested());
    await settle();
  }

  group('Prompt 40. the screen follows the authority', () {
    test('1. ACTIVE and confirmed: the screen is transmitted', () async {
      await reachActiveAssistance();

      expect(screenCapture.transmitting, isTrue);
      expect(screenCapture.transmissions, [(testRemoteSessionId, true)]);
      screenChanges();
      expect(screenCapture.framesSent, 3);
    });

    test('a new capture transmits nothing until the session is confirmed: '
        'opened only after the capture started', () async {
      remoteSessionRepository.currentResult = connectingRemoteSession;
      sessionBloc.add(const DeviceSessionStarted());
      await settle();
      realtimeBloc.add(const DeviceRealtimeStartRequested());
      await settle();
      await client.emit(const RealtimeConnected());
      await settle();
      final gate = screenCapture.startGate = Completer<void>();
      await client.deliver(offerReceived());
      await settle();

      // The dialog is still up: nothing captured, nothing transmitted.
      expect(screenCapture.transmitting, isFalse);
      gate.complete();
      await settle();

      // CONNECTING and confirmed: the technician sees the screen before
      // activating, as before this prompt.
      expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
      expect(screenCapture.transmitting, isTrue);
    });

    test('2-4. authority lost: control and screen suspended at once, '
        'MediaProjection kept', () async {
      final (peer, channel) = await reachActiveAssistance();
      screenChanges();

      await dropSocket();

      expect(screenCapture.transmitting, isFalse);
      expect(screenCapture.transmissions.last, (testRemoteSessionId, false));
      // Capture is not transmission: the projection and its consent stay.
      expect(screenCapture.isActive, isTrue);
      expect(screenCapture.stopCount, 0);
      expect(webRtcBloc.state.screenCapture, ScreenCaptureStatus.active);
      expect(peer.isClosed, isFalse);
      // The screen keeps changing; none of it reaches the technician.
      screenChanges(10);
      expect(screenCapture.framesSent, 3);
      expect(screenCapture.framesWithheld, 10);
      // And control is suspended with it.
      expect(await tapRuns(channel, 'while-down'), isFalse);
    });

    test('5-6. REST confirms the same ACTIVE session: screen and control '
        'come back, with no second consent and on the same peer', () async {
      final (peer, channel) = await reachActiveAssistance();
      await dropSocket();
      screenChanges(4);

      final gate = remoteSessionRepository.currentGate = Completer<void>();
      await restoreSocket();
      // Socket back, REST pending: still held back.
      expect(screenCapture.transmitting, isFalse);
      expect(await tapRuns(channel, 'pending'), isFalse);

      gate.complete();
      await settle();

      expect(screenCapture.transmitting, isTrue);
      expect(screenCapture.requests, [testRemoteSessionId]);
      expect(peerFactory.createCount, 1);
      expect(peer.isClosed, isFalse);
      expect(await tapRuns(channel, 'after'), isTrue);
      screenChanges(2);
      expect(screenCapture.framesSent, 2);
      expect(screenCapture.framesWithheld, 4);
    });

    test('7. REST failing: held back through every retry', () async {
      await reachActiveAssistance();
      await dropSocket();
      remoteSessionRepository.currentResult = remoteSessionUnreachable;
      await restoreSocket();

      for (final step in const [2, 4, 8, 8, 8]) {
        timers.elapse(Duration(seconds: step));
        await settle();
        expect(screenCapture.transmitting, isFalse);
        expect(screenCapture.isActive, isTrue);
      }
      expect(remoteSessionRepository.currentCount, greaterThan(4));
    });

    test('8. REST says the session is gone: capture and peer end, nothing '
        'reopens', () async {
      final (peer, channel) = await reachActiveAssistance();
      await dropSocket();
      final mark = screenCapture.transmissions.length;
      remoteSessionRepository.currentResult = noRemoteSession;

      await restoreSocket();

      expectNothingLeft(peer, channel);
      expect(screenCapture.transmitting, isFalse);
      expectNeverReopenedAfter(mark);
    });

    test('9. FINALIZAR during the suspension ends everything, and a later '
        'recovery reopens nothing', () async {
      final (peer, channel) = await reachActiveAssistance();
      await dropSocket();
      final mark = screenCapture.transmissions.length;

      await finalizar();
      // The close is confirmed at once (the fake answers 200 CLOSED). Since
      // Prompt 41 a confirmed close is proof the session is over, so the read
      // that follows it, still answering ACTIVE, no longer flips the state
      // back from Idle to ended-here: either way it is not live.
      expect(remoteSessionBloc.state, isNot(isA<RemoteSessionLive>()));
      expectNothingLeft(peer, channel);

      // The backend still says ACTIVE when the socket comes back.
      await restoreSocket();
      timers.elapse(const Duration(seconds: 30));
      await settle();
      screenChanges();

      expect(screenCapture.framesSent, 0);
      expectNeverReopenedAfter(mark);
      expect(screenCapture.requests, [testRemoteSessionId]);
    });

    test('10. SYSTEM close during the recovery wins over the read on the '
        'wire', () async {
      final (peer, channel) = await reachActiveAssistance();
      await dropSocket();
      final mark = screenCapture.transmissions.length;
      final gate = remoteSessionRepository.currentGate = Completer<void>();
      await restoreSocket();

      await client.emit(
        const RealtimeRemoteSessionClosed(
          testRemoteSessionId,
          endedBy: 'SYSTEM',
        ),
      );
      await settle();
      gate.complete();
      await settle();

      expectNothingLeft(peer, channel);
      expectNeverReopenedAfter(mark);
    });

    test('11. Android stops the projection while suspended: nothing is '
        'restarted or reopened by the recovery', () async {
      await reachActiveAssistance();
      await dropSocket();
      final mark = screenCapture.transmissions.length;

      screenCapture.endFromPlatform();
      await settle();
      await restoreSocket();

      expect(webRtcBloc.state.screenCapture, ScreenCaptureStatus.stoppedBySystem);
      expect(screenCapture.isActive, isFalse);
      expect(screenCapture.requests, [testRemoteSessionId]);
      expectNeverReopenedAfter(mark);
    });

    test('12. a replaced peer: the gate is the capture\'s, so a suspension '
        'holds for the old sender and the new one alike', () async {
      final (oldPeer, _) = await reachActiveAssistance();
      // The web gives up and offers from a new connection; authority is
      // confirmed, so it replaces the old peer and reuses the capture.
      await client.deliver(offerReceived(sdp: testSecondOfferSdp));
      await settle();
      final newPeer = peerFactory.last;
      expect(oldPeer.isClosed, isTrue);
      expect(newPeer.attachedScreenTracks, [testScreenVideoTrack]);
      // The running capture was handed back: never stopped, so no dialog.
      expect(screenCapture.stopCount, 0);
      expect(screenCapture.transmitting, isTrue);

      await dropSocket();

      expect(screenCapture.transmitting, isFalse);
      screenChanges();
      expect(screenCapture.framesSent, 0);
    });

    test('13. late callbacks from any generation never reopen the screen',
        () async {
      final (oldPeer, oldChannel) = await reachActiveAssistance();
      await client.deliver(offerReceived(sdp: testSecondOfferSdp));
      await settle();
      final newPeer = peerFactory.last;
      await dropSocket();

      // The old peer, the old channel and the current peer all report while
      // the tablet is suspended.
      oldPeer.pushConnectionState(WebRtcConnectionState.connected);
      oldChannel.pushState(WebRtcDataChannelState.open);
      newPeer.pushConnectionState(WebRtcConnectionState.connected);
      newPeer.pushConnectionState(WebRtcConnectionState.disconnected);
      newPeer.pushConnectionState(WebRtcConnectionState.connected);
      await settle();

      expect(screenCapture.transmitting, isFalse);
    });

    test('14. a recovery offer while suspended is refused; once confirmed, a '
        'new peer carries the screen', () async {
      final (peer, _) = await reachActiveAssistance();
      await dropSocket();
      await client.deliver(offerReceived(sdp: testSecondOfferSdp));
      await settle();
      expect(peerFactory.createCount, 1);
      expect(screenCapture.transmitting, isFalse);

      await restoreSocket();
      expect(screenCapture.transmitting, isTrue);
      expect(peer.isClosed, isFalse);
    });

    test('15. a DRAG held when the socket drops: the finger is abandoned and '
        'the screen held back at once', () async {
      final (_, channel) = await reachActiveAssistance();
      final handle = await holdFinger(channel);

      await dropSocket();

      expectAbandoned(handle);
      expect(screenCapture.transmitting, isFalse);
    });

    test('16. a new session gets its own consent, starts held back and is '
        'transmitted only once confirmed', () async {
      final (peer, channel) = await reachActiveAssistance();
      remoteSessionRepository.currentResult = noRemoteSession;
      await client.emit(
        const RealtimeRemoteSessionClosed(
          testRemoteSessionId,
          endedBy: 'TECHNICIAN',
        ),
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
      final gate = screenCapture.startGate = Completer<void>();
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
      expect(screenCapture.transmitting, isFalse);
      gate.complete();
      await settle();

      expect(screenCapture.requests, [
        testRemoteSessionId,
        testOtherRemoteSessionId,
      ]);
      expect(screenCapture.transmissions.last, (testOtherRemoteSessionId, true));
    });

    test('17. a loss longer than 75 s: held back the whole time, then the '
        'capture is stopped, never reopened', () async {
      final (peer, channel) = await reachActiveAssistance();
      remoteSessionRepository.currentResult = remoteSessionUnreachable;
      await dropSocket();
      final mark = screenCapture.transmissions.length;

      for (var s = 8; s <= 72; s += 8) {
        timers.elapse(const Duration(seconds: 8));
        await settle();
        expect(screenCapture.transmitting, isFalse);
        expect(screenCapture.isActive, isTrue);
      }
      timers.elapse(grace - const Duration(seconds: 72));
      await settle();

      expect(remoteSessionBloc.state, isA<RemoteSessionEndedLocally>());
      expectNothingLeft(peer, channel);
      remoteSessionRepository.currentResult = activatedRemoteSession;
      await restoreSocket();
      expectNeverReopenedAfter(mark);
    });

    test('18. several suspensions and recoveries: one change each, in order',
        () async {
      await reachActiveAssistance();

      for (var i = 0; i < 3; i++) {
        await dropSocket();
        // A second "down" with nothing in between changes nothing.
        await client.emit(const RealtimeDisconnected());
        await settle();
        await restoreSocket();
      }

      expect(screenCapture.transmissions, [
        (testRemoteSessionId, true),
        (testRemoteSessionId, false),
        (testRemoteSessionId, true),
        (testRemoteSessionId, false),
        (testRemoteSessionId, true),
        (testRemoteSessionId, false),
        (testRemoteSessionId, true),
      ]);
      expect(screenCapture.requests, [testRemoteSessionId]);
    });

    test('19. no new content reaches the technician without confirmed '
        'authority, at any step of a long scenario', () async {
      await reachActiveAssistance();
      var sentWhileUnconfirmed = 0;
      void step() {
        expectTransmissionFollowsAuthority();
        final before = screenCapture.framesSent;
        screenChanges();
        if (!authorityConfirmed()) {
          sentWhileUnconfirmed += screenCapture.framesSent - before;
        }
      }

      step();
      await dropSocket();
      step();
      remoteSessionRepository.currentResult = remoteSessionUnreachable;
      timers.elapse(const Duration(seconds: 2));
      await settle();
      step();
      await restoreSocket();
      step();
      remoteSessionRepository.currentResult = activatedRemoteSession;
      timers.elapse(const Duration(seconds: 4));
      await settle();
      step();
      await dropSocket();
      step();
      remoteSessionRepository.currentResult = noRemoteSession;
      timers.elapse(const Duration(seconds: 2));
      await settle();
      step();

      expect(sentWhileUnconfirmed, 0);
      expect(screenCapture.framesSent, 6);
      expect(screenCapture.isActive, isFalse);
    });

    test('20. after an irreversible close nothing reopens: not a socket flap, '
        'a late ACTIVE read, nor an old offer', () async {
      final (peer, channel) = await reachActiveAssistance();
      await finalizar();
      expectNothingLeft(peer, channel);
      final mark = screenCapture.transmissions.length;

      await dropSocket();
      final gate = remoteSessionRepository.currentGate = Completer<void>();
      await restoreSocket();
      gate.complete();
      await settle();
      await client.deliver(offerReceived(sdp: testSecondOfferSdp));
      await settle();

      expect(screenCapture.isActive, isFalse);
      expect(screenCapture.requests, [testRemoteSessionId]);
      expectNeverReopenedAfter(mark);
    });
  });

  group('Prompt 40. races', () {
    test('a read started before the drop and answering after it reopens '
        'nothing', () async {
      await reachActiveAssistance();
      final gate = remoteSessionRepository.currentGate = Completer<void>();
      remoteSessionBloc.add(const RemoteSessionSyncRequested());
      await settle();

      await dropSocket();
      gate.complete();
      await settle();

      expect(screenCapture.transmitting, isFalse);
    });

    test('authority lost while the user is still in the Android dialog: the '
        'capture starts held back', () async {
      remoteSessionRepository.currentResult = activatedRemoteSession;
      sessionBloc.add(const DeviceSessionStarted());
      await settle();
      realtimeBloc.add(const DeviceRealtimeStartRequested());
      await settle();
      await client.emit(const RealtimeConnected());
      await settle();
      final gate = screenCapture.startGate = Completer<void>();
      await client.deliver(offerReceived());
      await settle();

      await dropSocket();
      gate.complete();
      await settle();

      expect(screenCapture.isActive, isTrue);
      expect(screenCapture.transmitting, isFalse);
      expect(screenCapture.transmissions, isEmpty);

      await restoreSocket();
      expect(screenCapture.transmitting, isTrue);
    });

    test('a transmission the platform refuses stops the capture and reads as '
        'a failed screen; the assistance goes on', () async {
      final (peer, channel) = await reachActiveAssistance();
      screenCapture.transmissionFails = true;

      await dropSocket();

      expect(screenCapture.isActive, isFalse);
      expect(screenCapture.transmitting, isFalse);
      expect(webRtcBloc.state.screenCapture, ScreenCaptureStatus.failed);
      expect(peer.isClosed, isFalse);
      expect(channel.isClosed, isFalse);
      await restoreSocket();
      expect(await tapRuns(channel, 'after'), isTrue);
      expect(screenCapture.isActive, isFalse);
    });

    test('the bloc closing while suspended stops the capture and reopens '
        'nothing', () async {
      await reachActiveAssistance();
      await dropSocket();
      final mark = screenCapture.transmissions.length;

      await webRtcBloc.close();

      expect(screenCapture.isActive, isFalse);
      expectNeverReopenedAfter(mark);
    });
  });
}
