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
import 'package:remote_control_device/features/device/domain/usecases/clear_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
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
import '../fakes/realtime_fakes.dart';
import '../fakes/remote_control_fakes.dart';
import '../fakes/remote_session_fakes.dart';
import '../fakes/screen_capture_fakes.dart';
import '../fakes/signaling_fakes.dart';
import '../fakes/support_fakes.dart';
import '../fakes/webrtc_fakes.dart';

/// FINALIZAR ASISTENCIA pressed on the tablet, end to end: every bloc and
/// coordinator is the real one, and only the socket, HTTP, the secure store,
/// the native WebRTC stack, MediaProjection and the accessibility service are
/// faked.
///
/// The question is the one C1 raised: once the user ends the assistance, can
/// anything — a failed close, a late event, a reconnection, a stale offer, a
/// late screen grant — give the technician the tablet back? Every test here
/// says no, and checks it where it matters: no gesture reaches Android, the
/// peer connection is closed, and the screen is not captured.
void main() {
  late FakeDeviceRealtimeClient client;
  late FakeRemoteSessionRepository remoteSessionRepository;
  late FakeEndedRemoteSessionStore endedSessionStore;
  late FakeWebRtcPeerConnectionFactory peerFactory;
  late FakeScreenCaptureClient screenCapture;
  late FakeRemoteControlAccessibilityClient accessibility;
  late DeviceCredentialRevocation credentialRevocation;

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
      endedSessionStore: endedSessionStore,
    );
    signalingBloc = SignalingBloc(client: client);
    webRtcBloc = WebRtcSessionBloc(
      peerConnectionFactory: peerFactory,
      signaling: signalingBloc,
      iceConfiguration: const WebRtcIceConfiguration.none(),
      screenCapture: screenCapture,
      remoteControl: accessibility,
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

  test('Case A — the local end is complete before the backend answers, and '
      'the confirmed close settles it', () async {
    final (peer, channel) = await reachActiveAssistance();
    final gate = Completer<void>();
    remoteSessionRepository.closeGate = gate;
    remoteSessionRepository.currentQueue.add(noRemoteSession);
    // What had already been taken down when the screen capture was stopped.
    late final bool peerClosedBeforeCapture;
    screenCapture.onStop = () => peerClosedBeforeCapture = peer.isClosed;

    remoteSessionBloc.add(const RemoteSessionCloseRequested());
    await settle();

    // The backend has not answered, and everything is already gone.
    expect(remoteSessionRepository.closeCount, 1);
    expectNothingLeft(peer, channel);
    expect(peerClosedBeforeCapture, isTrue);

    gate.complete();
    await settle();

    expect(remoteSessionBloc.state, const RemoteSessionIdle());
    expect(endedSessionStore.value, isNull);
    expectNothingLeft(peer, channel);
  });

  test('Case B — a close the network loses leaves control, peer and capture '
      'all down', () async {
    final (peer, channel) = await reachActiveAssistance();
    remoteSessionRepository.closeResult = closeUnreachable;

    remoteSessionBloc.add(const RemoteSessionCloseRequested());
    await settle();

    expect(remoteSessionBloc.state, isA<RemoteSessionEndedLocally>());
    expectNothingLeft(peer, channel);
    // Exactly the one tap from before FINALIZAR.
    channel.pushTap('after');
    await settle();
    expect(accessibility.taps, hasLength(1));
    expect(endedSessionStore.value, testRemoteSessionId);
  });

  test('Case C — after the failed close, a reconnection reads ACTIVE and '
      'nothing comes back', () async {
    final (peer, channel) = await reachActiveAssistance();
    remoteSessionRepository.closeResult = closeUnreachable;
    remoteSessionBloc.add(const RemoteSessionCloseRequested());
    await settle();
    final joins = client.joinedSessionIds.length;
    final captureRequests = screenCapture.requests.length;

    // The socket drops and comes back; the backend still says ACTIVE.
    await client.emit(const RealtimeDisconnected());
    await settle();
    await client.emit(const RealtimeConnected());
    await settle();

    expect(remoteSessionBloc.state, isA<RemoteSessionEndedLocally>());
    // The close was sent again on the reconnection, once.
    expect(remoteSessionRepository.closeCount, 2);
    // The room was not re-entered, and the screen was not asked for again.
    expect(client.joinedSessionIds, hasLength(joins));
    expect(screenCapture.requests, hasLength(captureRequests));
    expect(peerFactory.createCount, 1);
    expectNothingLeft(peer, channel);
  });

  group('Case D — anything late from the ended session', () {
    test('a stale remote-session:active changes nothing', () async {
      final (peer, channel) = await reachActiveAssistance();
      remoteSessionRepository.closeResult = closeUnreachable;
      remoteSessionBloc.add(const RemoteSessionCloseRequested());
      await settle();

      await client.emit(
        const RealtimeRemoteSessionActivated(testRemoteSessionId),
      );
      await settle();

      expect(remoteSessionBloc.state, isA<RemoteSessionEndedLocally>());
      expectNothingLeft(peer, channel);
    });

    test('an old offer builds no peer connection, by either route', () async {
      final (peer, channel) = await reachActiveAssistance();
      remoteSessionRepository.closeResult = closeUnreachable;
      remoteSessionBloc.add(const RemoteSessionCloseRequested());
      await settle();

      // Over the wire: the room was left, so signaling drops it.
      await client.deliver(offerReceived(sdp: testSecondOfferSdp));
      await settle();
      // Straight at the WebRTC layer: no live session, so it drops it too.
      webRtcBloc.add(
        const WebRtcOfferReceived(
          WebRtcOffer(remoteSessionId: testRemoteSessionId, sdp: testSdp),
        ),
      );
      await settle();

      expect(peerFactory.createCount, 1);
      expect(client.sentAnswers, hasLength(1));
      expect(screenCapture.requests, [testRemoteSessionId]);
      expectNothingLeft(peer, channel);
    });

    test(
      'a data channel offered by the old peer is closed, not adopted',
      () async {
        final (peer, channel) = await reachActiveAssistance();
        remoteSessionRepository.closeResult = closeUnreachable;
        remoteSessionBloc.add(const RemoteSessionCloseRequested());
        await settle();

        // Whatever generation it claims, none is current any more.
        final reopened = FakeWebRtcDataChannel(
          label: 'control',
          initialState: WebRtcDataChannelState.open,
        );
        for (var generation = 0; generation < 6; generation++) {
          webRtcBloc.add(WebRtcDataChannelOffered(generation, reopened));
        }
        await settle();
        reopened.pushTap('via-reopened');
        await settle();

        expect(reopened.isClosed, isTrue);
        expect(accessibility.taps, hasLength(1));
        expectNothingLeft(peer, channel);
      },
    );

    test('a screen granted after FINALIZAR is stopped, not shared', () async {
      // FINALIZAR lands while the Android dialog is still waiting — the
      // capture is granted only afterwards.
      remoteSessionRepository.currentResult = connectingRemoteSession;
      sessionBloc.add(const DeviceSessionStarted());
      await settle();
      realtimeBloc.add(const DeviceRealtimeStartRequested());
      await settle();
      await client.emit(const RealtimeConnected());
      await settle();
      final dialog = Completer<void>();
      screenCapture.startGate = dialog;
      await client.deliver(offerReceived());
      await settle();
      expect(webRtcBloc.state.screenCapture, ScreenCaptureStatus.requesting);

      remoteSessionRepository.closeResult = closeUnreachable;
      remoteSessionBloc.add(const RemoteSessionCloseRequested());
      await settle();
      final stopsAtEnd = screenCapture.stopCount;

      dialog.complete();
      await settle();

      // The late grant was stopped on arrival and never attached or answered.
      expect(screenCapture.isActive, isFalse);
      expect(screenCapture.stopCount, greaterThan(stopsAtEnd));
      expect(peerFactory.last.isClosed, isTrue);
      expect(peerFactory.last.calls, isNot(contains('attachScreenVideo')));
      expect(client.sentAnswers, isEmpty);
      expect(webRtcBloc.state, const WebRtcIdle());
    });
  });

  test('Case E — a DRAG in progress is let go, never dropped', () async {
    final (peer, channel) = await reachActiveAssistance();
    pushHold(channel);
    await settle();
    accessibility.answerStart();
    await settle();
    expect(channel.sentAcks.last, const RemoteControlAck.success('hold-1'));
    final handle =
        (accessibility.touchCalls.single as (String, int, double, double)).$2;
    remoteSessionRepository.closeResult = closeUnreachable;

    remoteSessionRepository.closeGate = Completer<void>();
    remoteSessionBloc.add(const RemoteSessionCloseRequested());
    await settle();

    // The finger is abandoned on the Android side — not released, which would
    // complete the drag as a drop wherever it happened to be.
    expect(accessibility.touchCalls, [
      accessibility.touchCalls.first,
      ('abandon', handle),
    ]);
    expect(
      accessibility.touchCalls.whereType<(String, int, int, double, double)>(),
      isEmpty,
    );
    // Moves, a release or another hold after the end reach nothing.
    channel.pushFrame(
      const WebRtcDataChannelMessage.text(
        '{"v":1,"type":"touch_release","id":"rel-2","touch":"t-1",'
        '"seq":2,"x":0.6,"y":0.7}',
      ),
    );
    pushHold(channel);
    await settle();
    expect(accessibility.touchCalls, hasLength(2));
    expectNothingLeft(peer, channel);
    remoteSessionRepository.closeGate!.complete();
  });

  test('Case F — FINALIZAR twice ends once', () async {
    final (peer, channel) = await reachActiveAssistance();
    remoteSessionRepository.currentQueue.add(noRemoteSession);

    remoteSessionBloc
      ..add(const RemoteSessionCloseRequested())
      ..add(const RemoteSessionCloseRequested());
    await settle();

    expect(remoteSessionRepository.closeCount, 1);
    expect(peer.closeCount, 1);
    expect(channel.closeCount, 1);
    expect(peerFactory.createCount, 1);
    expect(screenCapture.requests, [testRemoteSessionId]);
    expectNothingLeft(peer, channel);
  });

  test(
    'Case H — a new assistance still starts through its own consent',
    () async {
      final (peer, channel) = await reachActiveAssistance();
      remoteSessionRepository.currentQueue.add(noRemoteSession);
      remoteSessionBloc.add(const RemoteSessionCloseRequested());
      await settle();
      expect(remoteSessionBloc.state, const RemoteSessionIdle());
      expectNothingLeft(peer, channel);

      // A new request, accepted with PERMITIR, and a new session for it.
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

      expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
      expect(peerFactory.createCount, 2);
      // The screen is asked for again, for the new session only.
      expect(screenCapture.requests, [
        testRemoteSessionId,
        testOtherRemoteSessionId,
      ]);
      expect(client.sentAnswers.last.remoteSessionId, testOtherRemoteSessionId);
    },
  );
}
