import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/pages/ready_page.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_device/features/remote_session/presentation/widgets/remote_session_panel.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/accept_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/cancel_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/load_current_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/reject_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/request_support.dart';
import 'package:remote_control_device/features/support/presentation/bloc/support/support_bloc.dart';
import 'package:remote_control_device/features/support/presentation/widgets/support_panel.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_device/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';
import 'package:remote_control_device/core/result/result.dart';

import '../../../fakes/device_fakes.dart';
import '../../../fakes/realtime_fakes.dart';
import '../../../fakes/remote_session_fakes.dart';
import '../../../fakes/support_fakes.dart';
import '../../../fakes/webrtc_fakes.dart';

/// Drives the real screen — `ReadyPage`, both panels, all three blocs — with
/// faked HTTP and a faked socket. What is under test is what the user sees at
/// each point of the lifecycle, and which of the two panels is in charge.
void main() {
  late FakeSupportRepository supportRepository;
  late FakeRemoteSessionRepository remoteSessionRepository;
  late FakeDeviceRealtimeClient client;
  late InMemoryDeviceTokenStore tokenStore;
  late SupportBloc supportBloc;
  late RemoteSessionBloc remoteSessionBloc;
  late DeviceRealtimeBloc realtimeBloc;
  late WebRtcSessionBloc webRtcBloc;
  late FakeWebRtcPeerConnectionFactory peerFactory;
  late FakeWebRtcSignalingGateway webRtcSignaling;

  /// Built inside the test body on purpose: a bloc created in `setUp` lives in
  /// a different zone from the one `testWidgets` drives, and `pump` would never
  /// run its continuations.
  void createBlocs() {
    supportRepository = FakeSupportRepository();
    remoteSessionRepository = FakeRemoteSessionRepository();
    client = FakeDeviceRealtimeClient();
    tokenStore = InMemoryDeviceTokenStore()..save(testDeviceJwt);

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
    realtimeBloc = DeviceRealtimeBloc(
      client: client,
      tokenStore: tokenStore,
      renewDeviceToken: RenewDeviceToken(
        loadDeviceCredentials: LoadDeviceCredentials(
          FakeDeviceCredentialsStorage(testCredentials),
        ),
        authenticateDevice: AuthenticateDevice(
          FakeDeviceAuthRepository(tokenStore: tokenStore),
        ),
      ),
    );
    peerFactory = FakeWebRtcPeerConnectionFactory();
    webRtcSignaling = FakeWebRtcSignalingGateway();
    webRtcBloc = WebRtcSessionBloc(
      peerConnectionFactory: peerFactory,
      signaling: webRtcSignaling,
      iceConfiguration: const WebRtcIceConfiguration.none(),
    );
    addTearDown(supportBloc.close);
    addTearDown(remoteSessionBloc.close);
    addTearDown(realtimeBloc.close);
    addTearDown(webRtcBloc.close);
  }

  Widget harness() => MultiBlocProvider(
    providers: [
      BlocProvider<SupportBloc>.value(value: supportBloc),
      BlocProvider<RemoteSessionBloc>.value(value: remoteSessionBloc),
      BlocProvider<DeviceRealtimeBloc>.value(value: realtimeBloc),
      BlocProvider<WebRtcSessionBloc>.value(value: webRtcBloc),
    ],
    child: const MaterialApp(home: ReadyPage(device: testIdentity)),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(Duration.zero);
    }
  }

  /// Puts the screen in the state this prompt starts from: the user authorised
  /// a technician, the channel is up, and no session exists yet.
  Future<void> pumpAccepted(WidgetTester tester) async {
    createBlocs();
    supportRepository.currentResult = const Ok<SupportRequest?>(acceptedRequest);
    await tester.pumpWidget(harness());

    realtimeBloc.add(const DeviceRealtimeStartRequested());
    client.push(const RealtimeConnected());
    supportBloc.add(const SupportSyncRequested());
    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle(tester);
  }

  testWidgets('ACCEPTED with no session yet keeps preparing, without an error',
      (tester) async {
    await pumpAccepted(tester);

    expect(find.text('Técnico autorizado'), findsOneWidget);
    expect(find.text('Preparando la asistencia...'), findsOneWidget);
    expect(find.byKey(RemoteSessionPanel.closeButtonKey), findsNothing);
    // Waiting for the technician to press "start" is not a failure.
    expect(find.textContaining('No se pudo'), findsNothing);
    expect(find.byKey(RemoteSessionPanel.closeButtonKey), findsNothing);
  });

  testWidgets('CONNECTING shows the technician and offers to end it',
      (tester) async {
    await pumpAccepted(tester);

    remoteSessionRepository.currentResult = connectingRemoteSession;
    remoteSessionBloc.add(
      const RemoteSessionAnnounced(testRemoteSessionId),
    );
    await settle(tester);

    expect(find.text('Asistencia remota'), findsOneWidget);
    expect(find.text('Conectando con el técnico...'), findsOneWidget);
    expect(find.text(testTechnicianName), findsOneWidget);
    expect(find.byKey(RemoteSessionPanel.closeButtonKey), findsOneWidget);
    // The support panel is no longer in charge.
    expect(find.text('Preparando la asistencia...'), findsNothing);
    expect(find.byKey(SupportPanel.requestButtonKey), findsNothing);
    // Nothing this build cannot actually do is announced.
    expect(find.textContaining('pantalla'), findsNothing);
    expect(find.textContaining('control'), findsNothing);
  });

  /// Negotiates a peer connection the way the coordinator would, and pushes it
  /// all the way to the success condition: connection connected, control
  /// channel open.
  Future<void> establishPeerConnection(WidgetTester tester) async {
    webRtcBloc.add(
      const WebRtcSignalingAvailabilityChanged(testRemoteSessionId),
    );
    webRtcBloc.add(const WebRtcRemoteSessionChanged(testRemoteSessionId));
    webRtcBloc.add(WebRtcOfferReceived(offerFor()));
    await settle(tester);

    final peer = peerFactory.last;
    peer.pushConnectionState(WebRtcConnectionState.connected);
    final channel = peer.pushDataChannel();
    await settle(tester);
    channel.pushState(WebRtcDataChannelState.open);
    await settle(tester);
  }

  testWidgets('a connected peer with an open control channel says so',
      (tester) async {
    await pumpAccepted(tester);
    remoteSessionRepository.currentResult = connectingRemoteSession;
    remoteSessionBloc.add(const RemoteSessionAnnounced(testRemoteSessionId));
    await settle(tester);
    expect(find.text('Conectando con el técnico...'), findsOneWidget);

    await establishPeerConnection(tester);

    // The backend row is still CONNECTING — nothing moves it to ACTIVE — and
    // the screen tells the user the truth anyway.
    expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
    expect(find.text('Conexión remota establecida'), findsOneWidget);
    expect(find.text('Conectando con el técnico...'), findsNothing);
    // Ending the assistance stays available; it matters most right here.
    expect(find.byKey(RemoteSessionPanel.closeButtonKey), findsOneWidget);
    // And still nothing this build cannot do is claimed.
    expect(find.textContaining('pantalla'), findsNothing);
  });

  testWidgets('half a connection is still connecting', (tester) async {
    await pumpAccepted(tester);
    remoteSessionRepository.currentResult = connectingRemoteSession;
    remoteSessionBloc.add(const RemoteSessionAnnounced(testRemoteSessionId));
    await settle(tester);

    webRtcBloc.add(
      const WebRtcSignalingAvailabilityChanged(testRemoteSessionId),
    );
    webRtcBloc.add(const WebRtcRemoteSessionChanged(testRemoteSessionId));
    webRtcBloc.add(WebRtcOfferReceived(offerFor()));
    await settle(tester);
    // Connected, but the control channel has not opened.
    peerFactory.last.pushConnectionState(WebRtcConnectionState.connected);
    await settle(tester);

    expect(find.text('Conectando con el técnico...'), findsOneWidget);
    expect(find.text('Conexión remota establecida'), findsNothing);
  });

  testWidgets('a lost socket outranks an established peer connection',
      (tester) async {
    await pumpAccepted(tester);
    remoteSessionRepository.currentResult = connectingRemoteSession;
    remoteSessionBloc.add(const RemoteSessionAnnounced(testRemoteSessionId));
    await settle(tester);
    await establishPeerConnection(tester);

    client.push(const RealtimeDisconnected());
    await settle(tester);

    // The peer connection may well still be up, but the tablet cannot be
    // reached by the backend, and that is what the user needs to know. Both the
    // connection field and the panel headline say it.
    expect(find.text('Reconectando...'), findsNWidgets(2));
    expect(find.text('Conexión remota establecida'), findsNothing);
    // Nothing was torn down: WebRTC is peer to peer and does not need the
    // socket that introduced the two ends.
    expect(webRtcBloc.state.isRemoteConnectionEstablished, isTrue);
  });

  testWidgets('ACTIVE says the assistance is under way, and nothing more',
      (tester) async {
    await pumpAccepted(tester);

    remoteSessionRepository.currentResult = activeRemoteSession;
    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle(tester);

    expect(find.text('Asistencia en curso'), findsOneWidget);
    expect(find.byKey(RemoteSessionPanel.closeButtonKey), findsOneWidget);
    expect(find.textContaining('Compartiendo'), findsNothing);
  });

  testWidgets('losing the channel says reconnecting, never that it ended',
      (tester) async {
    await pumpAccepted(tester);
    remoteSessionRepository.currentResult = connectingRemoteSession;
    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle(tester);

    client.push(const RealtimeDisconnected());
    await settle(tester);

    // The page's own connection line says it too; this is the panel's.
    expect(
      find.descendant(
        of: find.byType(RemoteSessionPanel),
        matching: find.text('Reconectando...'),
      ),
      findsOneWidget,
    );
    // The session is still there and can still be ended.
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(RemoteSessionPanel.closeButtonKey),
          )
          .onPressed,
      isNotNull,
    );
    expect(find.byKey(SupportPanel.requestButtonKey), findsNothing);
  });

  testWidgets('ending it from the tablet closes and returns to the request',
      (tester) async {
    await pumpAccepted(tester);
    remoteSessionRepository.currentResult = connectingRemoteSession;
    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle(tester);

    // The backend closes the session and completes its request together.
    remoteSessionRepository.currentQueue.add(noRemoteSession);
    supportRepository.currentResult = const Ok<SupportRequest?>(null);

    await tester.tap(find.byKey(RemoteSessionPanel.closeButtonKey));
    await settle(tester);

    expect(remoteSessionRepository.closedIds, [testRemoteSessionId]);
    // The support state is re-read by the coordinator in the application; here
    // the panel is simply handed back to the support bloc.
    expect(find.byKey(RemoteSessionPanel.closeButtonKey), findsNothing);
  });

  testWidgets('a second tap while closing cannot start another close',
      (tester) async {
    await pumpAccepted(tester);
    remoteSessionRepository.currentResult = connectingRemoteSession;
    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle(tester);

    // The close is held open so the state can be observed while it is in
    // flight — which is the only moment the guard matters.
    final gate = Completer<void>();
    remoteSessionRepository.closeGate = gate;
    remoteSessionRepository.currentQueue.add(noRemoteSession);

    await tester.tap(find.byKey(RemoteSessionPanel.closeButtonKey));
    await settle(tester);

    expect(find.text('Finalizando la asistencia...'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(RemoteSessionPanel.closeButtonKey),
          )
          .onPressed,
      isNull,
    );

    gate.complete();
    await settle(tester);
    expect(remoteSessionRepository.closeCount, 1);
  });

  testWidgets('an unknown session state offers to ask again, not to request',
      (tester) async {
    createBlocs();
    supportRepository.currentResult = const Ok<SupportRequest?>(null);
    remoteSessionRepository.currentResult = remoteSessionUnreachable;
    await tester.pumpWidget(harness());

    realtimeBloc.add(const DeviceRealtimeStartRequested());
    client.push(const RealtimeConnected());
    supportBloc.add(const SupportSyncRequested());
    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle(tester);

    // "There is no session" and "I could not find out" must never look the
    // same: offering assistance here would answer a question nobody answered.
    expect(find.byKey(SupportPanel.requestButtonKey), findsNothing);
    expect(
      find.text('No se pudo comprobar el estado de la asistencia.'),
      findsOneWidget,
    );

    remoteSessionRepository.currentResult = connectingRemoteSession;
    await tester.tap(find.byKey(RemoteSessionUnavailablePanel.retryButtonKey));
    await settle(tester);

    expect(find.text('Conectando con el técnico...'), findsOneWidget);
  });

  testWidgets('never shows a token, a secret or a backend message',
      (tester) async {
    await pumpAccepted(tester);
    remoteSessionRepository.currentResult = connectingRemoteSession;
    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle(tester);

    expect(find.textContaining(testDeviceSecret), findsNothing);
    expect(find.textContaining(testDeviceJwt), findsNothing);
    // Operational identifiers are safe to log but have no place on screen.
    expect(find.textContaining(testRemoteSessionId), findsNothing);
    expect(find.textContaining(testSupportRequestId), findsNothing);
  });
}
