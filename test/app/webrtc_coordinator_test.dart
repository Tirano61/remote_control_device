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
import 'package:remote_control_device/features/device/domain/usecases/clear_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';
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
import 'package:remote_control_device/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../fakes/device_fakes.dart';
import '../fakes/realtime_fakes.dart';
import '../fakes/remote_session_fakes.dart';
import '../fakes/signaling_fakes.dart';
import '../fakes/support_fakes.dart';
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
  late FakeWebRtcPeerConnectionFactory peerFactory;
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
    peerFactory = FakeWebRtcPeerConnectionFactory();
    credentialRevocation = DeviceCredentialRevocation();

    final loadDeviceCredentials = LoadDeviceCredentials(storage);
    final authenticateDevice = AuthenticateDevice(authRepository);

    sessionBloc = DeviceSessionBloc(
      loadDeviceCredentials: loadDeviceCredentials,
      authenticateDevice: authenticateDevice,
      checkDeviceStatus: CheckDeviceStatus(authRepository),
      clearDeviceCredentials: ClearDeviceCredentials(
        credentialsStorage: storage,
        authRepository: authRepository,
      ),
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
    );
    signalingBloc = SignalingBloc(client: client);
    webRtcBloc = WebRtcSessionBloc(
      peerConnectionFactory: peerFactory,
      // The real wiring: the signaling bloc is the gateway, narrowed to the two
      // messages an answerer sends.
      signaling: signalingBloc,
      iceConfiguration: const WebRtcIceConfiguration.none(),
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
      'createAnswer',
      'setLocalDescription',
    ]);
    expect(client.sentAnswers, hasLength(1));
    expect(client.sentAnswers.single.remoteSessionId, testRemoteSessionId);
    expect(client.sentAnswers.single.sdp, testLocalAnswerSdp);
    // The device answers; it never offers.
    expect(client.sentOffers, isEmpty);
    expect(webRtcBloc.state, const WebRtcConnecting(testRemoteSessionId));
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

  test('an offer for a session this device is not in is dropped twice over',
      () async {
    await reachJoined();

    await client.deliver(offerReceived(remoteSessionId: testOtherRemoteSessionId));
    await settle();

    // `SignalingBloc` drops it at the session filter and it never reaches the
    // WebRTC layer; the WebRTC layer would refuse it too.
    expect(peerFactory.createCount, 0);
    expect(webRtcBloc.state, const WebRtcIdle());
  });

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

  test('a socket that drops mid-negotiation abandons it', () async {
    await reachJoined();
    await client.deliver(offerReceived());
    await settle();
    final peer = peerFactory.last;

    await client.emit(const RealtimeDisconnected());
    await settle();

    expect(signalingBloc.state, const SignalingIdle());
    expect(webRtcBloc.state, const WebRtcIdle());
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
    expect(webRtcBloc.state, const WebRtcFailed(testRemoteSessionId));

    // The web comes back, rejoins, and creates a brand new offer. A previous
    // generation that failed is no reason to refuse it — that is exactly the
    // case a reload produces, and staying stuck on it would leave the tablet
    // unreachable for the rest of the assistance.
    await client.deliver(offerReceived(sdp: testSecondOfferSdp));
    await settle();

    expect(peerFactory.createCount, 2);
    expect(client.sentAnswers, hasLength(2));
    expect(peerFactory.last.remoteDescriptions.single.sdp, testSecondOfferSdp);
    expect(webRtcBloc.state, const WebRtcConnecting(testRemoteSessionId));
    // The device answered twice and offered never.
    expect(client.sentOffers, isEmpty);
  });
}
