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
import 'package:remote_control_device/features/device/domain/usecases/suspend_device_authorization.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_device/features/signaling/domain/entities/join_remote_session_result.dart';
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
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_capture_status.dart';
import 'package:remote_control_device/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../fakes/device_fakes.dart';
import '../fakes/realtime_fakes.dart';
import '../fakes/remote_control_fakes.dart';
import '../fakes/remote_session_fakes.dart';
import '../fakes/signaling_fakes.dart';
import '../fakes/support_fakes.dart';
import '../fakes/screen_capture_fakes.dart';
import '../fakes/webrtc_fakes.dart';

/// The whole path a real assistance takes, with only the socket, the HTTP
/// repositories, the secure store and the native WebRTC stack faked.
///
/// Every bloc and every coordinator is the real one, because the question this
/// file answers is one no single bloc can: does a `webrtc:offer` arriving on
/// the wire end up as a peer connection, and does a session the backend closed
/// take that peer connection with it.
void main() {
  late FakeDeviceRealtimeClient client;
  late FakeDeviceCredentialsStorage storage;
  late FakeDeviceAuthRepository authRepository;
  late FakeSupportRepository supportRepository;
  late FakeRemoteSessionRepository remoteSessionRepository;
  late FakeEndedRemoteSessionStore endedSessionStore;
  late FakeWebRtcPeerConnectionFactory peerFactory;
  late FakeScreenCaptureClient screenCapture;
  late FakeRemoteControlAccessibilityClient accessibility;
  late DeviceTokenStore tokenStore;
  late DeviceCredentialRevocation credentialRevocation;

  late DeviceSessionBloc sessionBloc;
  late DeviceRealtimeBloc realtimeBloc;
  late SupportBloc supportBloc;
  late RemoteSessionBloc remoteSessionBloc;
  late SignalingBloc signalingBloc;
  late WebRtcSessionBloc webRtcBloc;

  late DeviceRealtimeCoordinator realtimeCoordinator;
  late SupportCoordinator supportCoordinator;
  late RemoteSessionCoordinator remoteSessionCoordinator;
  late SignalingCoordinator signalingCoordinator;
  late WebRtcCoordinator coordinator;

  setUp(() {
    client = FakeDeviceRealtimeClient();
    storage = FakeDeviceCredentialsStorage(testCredentials);
    tokenStore = InMemoryDeviceTokenStore();
    authRepository = FakeDeviceAuthRepository(tokenStore: tokenStore);
    supportRepository = FakeSupportRepository();
    remoteSessionRepository = FakeRemoteSessionRepository();
    endedSessionStore = FakeEndedRemoteSessionStore();
    peerFactory = FakeWebRtcPeerConnectionFactory();
    credentialRevocation = DeviceCredentialRevocation();

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
    );
    signalingBloc = SignalingBloc(client: client);
    screenCapture = FakeScreenCaptureClient();
    accessibility = FakeRemoteControlAccessibilityClient();
    webRtcBloc = WebRtcSessionBloc(
      peerConnectionFactory: peerFactory,
      // The real wiring: the signaling bloc is the gateway, narrowed to the two
      // messages an answerer sends.
      signaling: signalingBloc,
      iceConfiguration: const WebRtcIceConfiguration.none(),
      screenCapture: screenCapture,
      remoteControl: accessibility,
    );

    realtimeCoordinator = DeviceRealtimeCoordinator(
      sessionBloc: sessionBloc,
      realtimeBloc: realtimeBloc,
      credentialRevocation: credentialRevocation,
    )..start();
    supportCoordinator = SupportCoordinator(
      realtimeClient: client,
      realtimeBloc: realtimeBloc,
      sessionBloc: sessionBloc,
      supportBloc: supportBloc,
    )..start();
    remoteSessionCoordinator = RemoteSessionCoordinator(
      realtimeClient: client,
      realtimeBloc: realtimeBloc,
      sessionBloc: sessionBloc,
      supportBloc: supportBloc,
      remoteSessionBloc: remoteSessionBloc,
    )..start();
    signalingCoordinator = SignalingCoordinator(
      realtimeBloc: realtimeBloc,
      remoteSessionBloc: remoteSessionBloc,
      signalingBloc: signalingBloc,
    )..start();
    coordinator = WebRtcCoordinator(
      signalingBloc: signalingBloc,
      remoteSessionBloc: remoteSessionBloc,
      webRtcBloc: webRtcBloc,
    )..start();
  });

  tearDown(() async {
    await coordinator.dispose();
    await signalingCoordinator.dispose();
    await remoteSessionCoordinator.dispose();
    await supportCoordinator.dispose();
    await realtimeCoordinator.dispose();
    await credentialRevocation.dispose();
    await webRtcBloc.close();
    await signalingBloc.close();
    await remoteSessionBloc.close();
    await supportBloc.close();
    await realtimeBloc.close();
    await sessionBloc.close();
  });

  Future<void> settle() async {
    for (var i = 0; i < 16; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Authenticated, socket up, remote session live and signaling joined —
  /// everything the technician's offer will be checked against.
  Future<void> reachJoined() async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    sessionBloc.add(const DeviceSessionStarted());
    await settle();
    realtimeBloc.add(const DeviceRealtimeStartRequested());
    await settle();
    await client.emit(const RealtimeConnected());
    await settle();
  }

  test('a joined device with a ready peer still creates nothing', () async {
    client.joinResult = const RemoteSessionJoined('', peerJoined: true);
    await reachJoined();

    expect(
      signalingBloc.state,
      const SignalingJoined(testRemoteSessionId, peerJoined: true),
    );
    // Readiness is not a cue. The device is the answerer and waits for the
    // offer the web is about to make.
    expect(peerFactory.createCount, 0);
    expect(webRtcBloc.state, const WebRtcIdle());
    expect(client.sentOffers, isEmpty);
  });

  test('an offer on the wire becomes an answer on the wire', () async {
    await reachJoined();

    await client.deliver(offerReceived());
    await settle();

    expect(peerFactory.createCount, 1);
    expect(peerFactory.last.calls, [
      'setRemoteDescription',
      // The screen goes on before the answer is written, so the SDP describes
      // a video section this end is already sending on.
      'attachScreenVideo',
      'createAnswer',
      'setLocalDescription',
    ]);
    expect(client.sentAnswers, hasLength(1));
    expect(client.sentAnswers.single.remoteSessionId, testRemoteSessionId);
    expect(client.sentAnswers.single.sdp, testLocalAnswerSdp);
    // The device answers; it never offers.
    expect(client.sentOffers, isEmpty);
    expect(
      webRtcBloc.state,
      const WebRtcConnecting(
        testRemoteSessionId,
        screenCapture: ScreenCaptureStatus.active,
      ),
    );
  });

  test('a relayed candidate reaches the peer connection', () async {
    await reachJoined();
    await client.deliver(offerReceived());
    await settle();

    await client.deliver(iceCandidateReceived());
    await settle();

    expect(peerFactory.last.addedRemoteCandidates, hasLength(1));
    expect(
      peerFactory.last.addedRemoteCandidates.single.candidate,
      testIceCandidate,
    );
  });

  test('a local candidate reaches the wire after the answer', () async {
    await reachJoined();
    await client.deliver(offerReceived());
    await settle();

    peerFactory.last.pushLocalCandidate(localCandidate('candidate:A'));
    await settle();

    expect(client.sentIceCandidates, hasLength(1));
    expect(client.sentIceCandidates.single.candidate, 'candidate:A');
    expect(
      client.sentIceCandidates.single.remoteSessionId,
      testRemoteSessionId,
    );
  });

  test(
    'an offer for a session this device is not in is dropped twice over',
    () async {
      await reachJoined();

      await client.deliver(
        offerReceived(remoteSessionId: testOtherRemoteSessionId),
      );
      await settle();

      // `SignalingBloc` drops it at the session filter and it never reaches the
      // WebRTC layer; the WebRTC layer would refuse it too.
      expect(peerFactory.createCount, 0);
      expect(webRtcBloc.state, const WebRtcIdle());
    },
  );

  test('an answer relayed to this device is ignored, not applied', () async {
    await reachJoined();
    await client.deliver(offerReceived());
    await settle();
    final peer = peerFactory.last;
    final callsAfterOffer = [...peer.calls];

    // The device is the answerer: nothing answers it. An answer here would be
    // the web replying to an offer that was never made.
    await client.deliver(answerReceived());
    await settle();

    expect(peer.calls, callsAfterOffer);
  });

  test('the technician closing the session takes the peer with it', () async {
    await reachJoined();
    await client.deliver(offerReceived());
    await settle();
    final peer = peerFactory.last;
    peer.pushConnectionState(WebRtcConnectionState.connected);
    final channel = peer.pushDataChannel();
    await settle();
    channel.pushState(WebRtcDataChannelState.open);
    await settle();
    expect(webRtcBloc.state.isRemoteConnectionEstablished, isTrue);

    // remote-session:closed arrives, the session is re-read over REST, and the
    // empty answer is what ends it — the event alone never does.
    remoteSessionRepository.currentResult = noRemoteSession;
    await client.emit(const RealtimeRemoteSessionClosed(testRemoteSessionId));
    await settle();

    expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
    expect(webRtcBloc.state, const WebRtcIdle());
    expect(peer.isClosed, isTrue);
    expect(channel.isClosed, isTrue);
  });

  test('the tablet closing the assistance takes the peer with it', () async {
    await reachJoined();
    await client.deliver(offerReceived());
    await settle();
    final peer = peerFactory.last;
    peer.pushConnectionState(WebRtcConnectionState.connected);
    await settle();

    // FINALIZAR ASISTENCIA. The REST answer is what clears WebRTC, not the
    // button: the same path runs when the technician closes first.
    remoteSessionRepository.currentQueue.add(noRemoteSession);
    remoteSessionBloc.add(const RemoteSessionCloseRequested());
    await settle();

    expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
    expect(webRtcBloc.state, const WebRtcIdle());
    expect(peer.isClosed, isTrue);
  });

  test(
    'a session moving to ACTIVE leaves the peer connection untouched',
    () async {
      await reachJoined();
      await client.deliver(offerReceived());
      await settle();
      final peer = peerFactory.last;
      peer.pushConnectionState(WebRtcConnectionState.connected);
      final channel = peer.pushDataChannel();
      await settle();
      channel.pushState(WebRtcDataChannelState.open);
      await settle();
      expect(webRtcBloc.state.isRemoteConnectionEstablished, isTrue);
      expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
      final joined = signalingBloc.state;
      final joins = client.joinedSessionIds.length;

      // This is exactly what the web does next: seeing its own connection up and
      // the control channel open, it calls POST /remote-sessions/:id/activate.
      // The backend commits ACTIVE and announces it here.
      remoteSessionRepository.currentResult = activatedRemoteSession;
      await client.emit(
        const RealtimeRemoteSessionActivated(testRemoteSessionId),
      );
      await settle();

      expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
      // ACTIVE is a backend fact about the connection that already exists. It is
      // not a cue to negotiate anything, and nothing here treats it as one.
      expect(peer.isClosed, isFalse);
      expect(channel.isClosed, isFalse);
      expect(
        webRtcBloc.state,
        const WebRtcConnected(
          testRemoteSessionId,
          controlChannel: WebRtcDataChannelState.open,
          screenCapture: ScreenCaptureStatus.active,
        ),
      );
      expect(peerFactory.createCount, 1);
      expect(client.sentAnswers, hasLength(1));
      expect(client.sentOffers, isEmpty);
      // And the signaling room is not re-entered: it was never left, and the
      // contract accepts CONNECTING and ACTIVE alike as a live session.
      expect(client.joinedSessionIds, hasLength(joins));
      expect(signalingBloc.state, joined);
    },
  );

  test(
    'an ACTIVE session recovered on a restart keeps the same negotiation',
    () async {
      // The whole path in the order the real system produces it: the session is
      // still CONNECTING when the offer arrives, the peer comes up, and only
      // then does the backend row move — through a plain read, with no event at
      // all, which is what a tablet that was offline or restarted would do.
      await reachJoined();
      await client.deliver(offerReceived());
      await settle();
      final peer = peerFactory.last;
      peer.pushConnectionState(WebRtcConnectionState.connected);
      final channel = peer.pushDataChannel();
      await settle();
      channel.pushState(WebRtcDataChannelState.open);
      await settle();

      remoteSessionRepository.currentResult = activatedRemoteSession;
      remoteSessionBloc.add(const RemoteSessionSyncRequested());
      await settle();

      expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
      expect(peer.isClosed, isFalse);
      expect(channel.isClosed, isFalse);
      expect(webRtcBloc.state.isRemoteConnectionEstablished, isTrue);
      expect(peerFactory.createCount, 1);
    },
  );

  test('a socket that drops mid-negotiation abandons it', () async {
    await reachJoined();
    await client.deliver(offerReceived());
    await settle();
    final peer = peerFactory.last;

    await client.emit(const RealtimeDisconnected());
    await settle();

    expect(signalingBloc.state, const SignalingIdle());
    // The peer connection goes; the screen does not. The backend still holds
    // the remote session, and the web will offer again after its own rejoin.
    expect(
      webRtcBloc.state,
      const WebRtcIdle(screenCapture: ScreenCaptureStatus.active),
    );
    expect(screenCapture.stopCount, 0);
    expect(peer.isClosed, isTrue);
  });

  test('a socket that drops after connecting leaves the peer alone', () async {
    await reachJoined();
    await client.deliver(offerReceived());
    await settle();
    final peer = peerFactory.last;
    peer.pushConnectionState(WebRtcConnectionState.connected);
    final channel = peer.pushDataChannel();
    await settle();
    channel.pushState(WebRtcDataChannelState.open);
    await settle();

    await client.emit(const RealtimeDisconnected());
    await settle();
    // And back: the socket rejoins, and nothing renegotiates.
    await client.emit(const RealtimeConnected());
    await settle();

    expect(peer.isClosed, isFalse);
    expect(channel.isClosed, isFalse);
    expect(peerFactory.createCount, 1);
    expect(client.sentAnswers, hasLength(1));
    expect(webRtcBloc.state.isRemoteConnectionEstablished, isTrue);
  });

  test('the web reloading is answered with a second negotiation', () async {
    await reachJoined();
    await client.deliver(offerReceived());
    await settle();
    final first = peerFactory.last;
    first.pushConnectionState(WebRtcConnectionState.connected);
    await settle();

    // F5 destroys the browser's peer connection. This side sees it fail.
    first.pushConnectionState(WebRtcConnectionState.failed);
    await settle();
    expect(
      webRtcBloc.state,
      const WebRtcFailed(
        testRemoteSessionId,
        screenCapture: ScreenCaptureStatus.active,
      ),
    );

    // The web comes back, rejoins, and creates a brand new offer. A previous
    // generation that failed is no reason to refuse it — that is exactly the
    // case a reload produces, and staying stuck on it would leave the tablet
    // unreachable for the rest of the assistance.
    await client.deliver(offerReceived(sdp: testSecondOfferSdp));
    await settle();

    expect(peerFactory.createCount, 2);
    expect(client.sentAnswers, hasLength(2));
    expect(peerFactory.last.remoteDescriptions.single.sdp, testSecondOfferSdp);
    expect(
      webRtcBloc.state,
      const WebRtcConnecting(
        testRemoteSessionId,
        screenCapture: ScreenCaptureStatus.active,
      ),
    );
    // Two negotiations, one capture: the user authorised their screen once.
    expect(screenCapture.requests, [testRemoteSessionId, testRemoteSessionId]);
    expect(screenCapture.stopCount, 0);
    // The device answered twice and offered never.
    expect(client.sentOffers, isEmpty);
  });

  group('a tap and the remote session it arrives in', () {
    /// The peer up and the control channel open, with the session still
    /// `CONNECTING`: the moment just before the web activates it.
    Future<FakeWebRtcDataChannel> reachOpenChannel() async {
      await reachJoined();
      await client.deliver(offerReceived());
      await settle();
      final peer = peerFactory.last;
      peer.pushConnectionState(WebRtcConnectionState.connected);
      final channel = peer.pushDataChannel();
      await settle();
      channel.pushState(WebRtcDataChannelState.open);
      await settle();
      return channel;
    }

    Future<void> activate() async {
      remoteSessionRepository.currentResult = activatedRemoteSession;
      await client.emit(
        const RealtimeRemoteSessionActivated(testRemoteSessionId),
      );
      await settle();
    }

    test('CONNECTING: no gesture, session_not_active', () async {
      final channel = await reachOpenChannel();

      channel.pushTap('t-1');
      await settle();

      expect(accessibility.taps, isEmpty);
      expect(channel.sentAcks, const [
        RemoteControlAck.failure('t-1', RemoteControlError.sessionNotActive),
      ]);
    });

    test('ACTIVE: the same channel now runs the gesture', () async {
      final channel = await reachOpenChannel();
      await activate();

      channel.pushTap('t-1');
      await settle();

      expect(accessibility.taps, [(0.5, 0.5)]);
      expect(channel.sentAcks, const [RemoteControlAck.success('t-1')]);
    });

    test(
      'pressing FINALIZAR stops the gestures before the backend answers',
      () async {
        final channel = await reachOpenChannel();
        await activate();
        final closing = Completer<void>();
        remoteSessionRepository.closeGate = closing;

        remoteSessionBloc.add(const RemoteSessionCloseRequested());
        await settle();
        // Ended here while the backend has still said nothing.
        expect(
          remoteSessionBloc.state,
          const RemoteSessionEndedLocally(
            testRemoteSessionId,
            confirming: true,
          ),
        );

        channel.pushTap('after-end');
        await settle();

        // Not even refused: the channel it would have come in on is closed.
        expect(accessibility.taps, isEmpty);
        expect(channel.isClosed, isTrue);
        expect(channel.sentAcks, isEmpty);

        closing.complete();
      },
    );

    test(
      'a session the backend closed runs nothing that arrives late',
      () async {
        final channel = await reachOpenChannel();
        await activate();

        remoteSessionRepository.currentResult = noRemoteSession;
        await client.emit(
          const RealtimeRemoteSessionClosed(testRemoteSessionId),
        );
        await settle();

        channel.pushTap('late');
        await settle();

        expect(accessibility.taps, isEmpty);
        expect(channel.isClosed, isTrue);
      },
    );

    test('E2E F: the web offers from a new connection while this peer still '
        'reads CONNECTED; it is replaced and control comes back', () async {
      final oldChannel = await reachOpenChannel();
      await activate();
      final old = peerFactory.last;
      oldChannel.pushTap('t-1');
      await settle();
      expect(accessibility.taps, hasLength(1));

      await client.deliver(offerReceived(sdp: testSecondOfferSdp));
      await settle();

      expect(old.isClosed, isTrue);
      expect(oldChannel.isClosed, isTrue);
      expect(peerFactory.createCount, 2);
      expect(client.sentAnswers, hasLength(2));
      expect(client.sentOffers, isEmpty);

      final peer = peerFactory.last;
      peer.pushConnectionState(WebRtcConnectionState.connected);
      final channel = peer.pushDataChannel();
      await settle();
      channel.pushState(WebRtcDataChannelState.open);
      await settle();
      channel.pushTap('t-2');
      oldChannel.pushTap('t-old');
      await settle();

      expect(accessibility.taps, hasLength(2));
      expect(channel.sentAcks, const [RemoteControlAck.success('t-2')]);
      // One capture for the whole assistance, never stopped in between.
      expect(screenCapture.stopCount, 0);
      expect(
        webRtcBloc.state,
        const WebRtcConnected(
          testRemoteSessionId,
          controlChannel: WebRtcDataChannelState.open,
          screenCapture: ScreenCaptureStatus.active,
        ),
      );
    });

    test('a recovery offer is not answered until a read after the reconnection '
        'confirms the session', () async {
      final oldChannel = await reachOpenChannel();
      await activate();
      final old = peerFactory.last;
      final reading = Completer<void>();
      remoteSessionRepository.currentGate = reading;

      await client.emit(const RealtimeDisconnected());
      await settle();
      await client.emit(const RealtimeConnected());
      await settle();
      expect(
        remoteSessionBloc.state,
        isA<RemoteSessionActive>().having(
          (state) => state.authority,
          'authority',
          RemoteSessionAuthority.suspended,
        ),
      );

      await client.deliver(offerReceived(sdp: testSecondOfferSdp));
      await settle();
      expect(peerFactory.createCount, 1);
      expect(old.isClosed, isFalse);
      expect(oldChannel.isClosed, isFalse);

      reading.complete();
      remoteSessionRepository.currentGate = null;
      await settle();
      expect(
        remoteSessionBloc.state,
        isA<RemoteSessionActive>().having(
          (state) => state.authority,
          'authority',
          RemoteSessionAuthority.confirmed,
        ),
      );

      // Confirmed: an offer from that connection, if the web sends it again,
      // now replaces the peer. (Today's web does not resend on its own: it has
      // no answer deadline. See docs/webrtc/PEER_RECOVERY.md.)
      await client.deliver(offerReceived(sdp: testSecondOfferSdp));
      await settle();
      expect(peerFactory.createCount, 2);
      expect(old.isClosed, isTrue);
    });

    test('a tap does not disturb the screen capture', () async {
      final channel = await reachOpenChannel();
      await activate();

      channel.pushTap('t-1');
      await settle();

      expect(screenCapture.stopCount, 0);
      expect(
        webRtcBloc.state,
        const WebRtcConnected(
          testRemoteSessionId,
          controlChannel: WebRtcDataChannelState.open,
          screenCapture: ScreenCaptureStatus.active,
        ),
      );
    });
  });
  group('19. authentication during a live assistance', () {
    Future<(FakeWebRtcPeerConnection, FakeWebRtcDataChannel)>
    reachActive() async {
      await reachJoined();
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
      expect(screenCapture.isActive, isTrue);
      return (peer, channel);
    }

    test('a confirmed rejection ends the screen, the peer and remote control, '
        'and keeps the credential', () async {
      final (peer, channel) = await reachActive();

      // A renewal login somewhere answered 401 DEVICE_CREDENTIAL_REJECTED.
      credentialRevocation.report();
      await settle();

      expect(sessionBloc.state, const DeviceSessionCredentialRefused());
      expect(tokenStore.hasToken, isFalse);
      expect(realtimeBloc.state, isA<DeviceRealtimeDisconnected>());
      expect(remoteSessionBloc.state, const RemoteSessionInitial());
      expect(webRtcBloc.state, const WebRtcIdle());
      expect(peer.isClosed, isTrue);
      expect(channel.isClosed, isTrue);
      expect(screenCapture.isActive, isFalse);
      expect(screenCapture.stopCount, 1);
      // The credential survives the refusal; the authorisation does not.
      expect(storage.credentials, testCredentials);
      expect(storage.clearCount, 0);

      // A command that still makes it across runs nothing.
      channel.pushTap('t-late');
      await settle();
      expect(accessibility.taps, isEmpty);
    });

    test('a refused handshake whose renewal confirms nothing is not a '
        'rejection', () async {
      final (peer, _) = await reachActive();

      // The socket is refused and the renewal login gets a private tunnel's
      // 401: nothing is known about the credential.
      authRepository.loginResult = loginUnauthorized;
      await client.emit(const RealtimeHandshakeRejected());
      await settle();

      expect(sessionBloc.state, const DeviceSessionReady(testIdentity));
      expect(storage.credentials, testCredentials);
      // The channel is down, which the remote-session lifecycle already
      // handles as a lost connection — not as a lost credential.
      expect(realtimeBloc.state, const DeviceRealtimeConnectionError());
      expect(peer.isClosed, isFalse);
    });

    test('P35: io server disconnect suspends control at once; a reconnection '
        'whose read finds the session gone does not bring it back', () async {
      final (peer, channel) = await reachActive();

      await client.emit(const RealtimeServerDisconnected());
      await settle();

      // Re-authenticating, not connected: authority is suspended right now,
      // before any read, and a gesture that arrives runs nothing.
      expect(sessionBloc.state, const DeviceSessionReady(testIdentity));
      expect(realtimeBloc.state, isNot(isA<DeviceRealtimeConnected>()));
      final suspended = remoteSessionBloc.state;
      expect(suspended, isA<RemoteSessionActive>());
      expect((suspended as RemoteSessionActive).isSuspended, isTrue);
      channel.pushTap('t-suspended');
      await settle();
      expect(accessibility.taps, isEmpty);

      // The new socket connects, but the backend closed the session meanwhile.
      remoteSessionRepository.currentResult = noRemoteSession;
      await client.emit(const RealtimeConnected());
      await settle();

      expect(remoteSessionBloc.state, isNot(isA<RemoteSessionLive>()));
      expect(peer.isClosed, isTrue);
      expect(screenCapture.isActive, isFalse);
      channel.pushTap('t-after');
      await settle();
      expect(accessibility.taps, isEmpty);
      // The renewal re-checked the credential; nothing was wiped.
      expect(storage.clearCount, 0);
    });

    test('P35: a reconnection whose read confirms ACTIVE restores control on '
        'the same channel, and only after that read', () async {
      final (peer, channel) = await reachActive();

      await client.emit(const RealtimeServerDisconnected());
      await settle();
      channel.pushTap('t-suspended');
      await settle();
      expect(accessibility.taps, isEmpty);

      remoteSessionRepository.currentResult = activatedRemoteSession;
      await client.emit(const RealtimeConnected());
      await settle();

      final live = remoteSessionBloc.state;
      expect(live, isA<RemoteSessionActive>());
      expect((live as RemoteSessionActive).isSuspended, isFalse);
      expect(peer.isClosed, isFalse);
      channel.pushTap('t-confirmed');
      await settle();
      // The gesture sent while suspended stays dropped; the new one runs.
      expect(accessibility.taps, [(0.5, 0.5)]);
    });
  });
}
