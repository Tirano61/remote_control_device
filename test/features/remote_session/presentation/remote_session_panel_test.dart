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
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';
import 'package:remote_control_device/features/remote_control/presentation/bloc/remote_control_accessibility/remote_control_accessibility_bloc.dart';
import 'package:remote_control_device/features/remote_control/presentation/widgets/remote_control_status.dart';
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
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_capture_result.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_device/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';
import 'package:remote_control_device/core/result/result.dart';

import '../../../fakes/manual_timers.dart';
import '../../../fakes/device_fakes.dart';
import '../../../fakes/realtime_fakes.dart';
import '../../../fakes/remote_control_fakes.dart';
import '../../../fakes/remote_session_fakes.dart';
import '../../../fakes/support_fakes.dart';
import '../../../fakes/screen_capture_fakes.dart';
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
  late ManualTimers timers;
  late RemoteSessionBloc remoteSessionBloc;
  late DeviceRealtimeBloc realtimeBloc;
  late WebRtcSessionBloc webRtcBloc;
  late FakeWebRtcPeerConnectionFactory peerFactory;
  late FakeScreenCaptureClient screenCapture;
  late FakeWebRtcSignalingGateway webRtcSignaling;
  late FakeRemoteControlAccessibilityClient accessibility;
  late RemoteControlAccessibilityBloc remoteControlAccessibilityBloc;

  /// Built inside the test body on purpose: a bloc created in `setUp` lives in
  /// a different zone from the one `testWidgets` drives, and `pump` would never
  /// run its continuations.
  void createBlocs() {
    timers = ManualTimers();
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
      endedSessionStore: FakeEndedRemoteSessionStore(),
      // Deadlines never fire on their own inside testWidgets' fake clock.
      timerFactory: timers.factory,
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
    screenCapture = FakeScreenCaptureClient();
    accessibility = FakeRemoteControlAccessibilityClient();
    webRtcBloc = WebRtcSessionBloc(
      peerConnectionFactory: peerFactory,
      signaling: webRtcSignaling,
      iceConfiguration: const WebRtcIceConfiguration.none(),
      screenCapture: screenCapture,
      remoteControl: accessibility,
      timerFactory: timers.factory,
    );
    remoteControlAccessibilityBloc = RemoteControlAccessibilityBloc(
      client: accessibility,
    )..add(const RemoteControlAccessibilityStarted());
    addTearDown(supportBloc.close);
    addTearDown(remoteSessionBloc.close);
    addTearDown(realtimeBloc.close);
    addTearDown(webRtcBloc.close);
    addTearDown(remoteControlAccessibilityBloc.close);
    // What RemoteSessionCoordinator does in the application: the session's
    // authority hangs on the realtime channel being up.
    final authority = realtimeBloc.stream.listen(
      (state) => remoteSessionBloc.add(
        RemoteSessionAuthorityChannelChanged(
          available: state is DeviceRealtimeConnected,
        ),
      ),
    );
    addTearDown(authority.cancel);
  }

  Widget harness() => MultiBlocProvider(
    providers: [
      BlocProvider<SupportBloc>.value(value: supportBloc),
      BlocProvider<RemoteSessionBloc>.value(value: remoteSessionBloc),
      BlocProvider<DeviceRealtimeBloc>.value(value: realtimeBloc),
      BlocProvider<WebRtcSessionBloc>.value(value: webRtcBloc),
      BlocProvider<RemoteControlAccessibilityBloc>.value(
        value: remoteControlAccessibilityBloc,
      ),
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
    supportRepository.currentResult = const Ok<SupportRequest?>(
      acceptedRequest,
    );
    await tester.pumpWidget(harness());

    realtimeBloc.add(const DeviceRealtimeStartRequested());
    client.push(const RealtimeConnected());
    supportBloc.add(const SupportSyncRequested());
    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle(tester);
  }

  testWidgets(
    'ACCEPTED with no session yet keeps preparing, without an error',
    (tester) async {
      await pumpAccepted(tester);

      expect(find.text('Técnico autorizado'), findsOneWidget);
      expect(find.text('Preparando la asistencia...'), findsOneWidget);
      expect(find.byKey(RemoteSessionPanel.closeButtonKey), findsNothing);
      // Waiting for the technician to press "start" is not a failure.
      expect(find.textContaining('No se pudo'), findsNothing);
      expect(find.byKey(RemoteSessionPanel.closeButtonKey), findsNothing);
    },
  );

  testWidgets('CONNECTING shows the technician and offers to end it', (
    tester,
  ) async {
    await pumpAccepted(tester);

    remoteSessionRepository.currentResult = connectingRemoteSession;
    remoteSessionBloc.add(const RemoteSessionAnnounced(testRemoteSessionId));
    await settle(tester);

    expect(find.text('Asistencia remota'), findsOneWidget);
    expect(find.text('Conectando con el técnico...'), findsOneWidget);
    expect(find.text(testTechnicianName), findsOneWidget);
    expect(find.byKey(RemoteSessionPanel.closeButtonKey), findsOneWidget);
    // The support panel is no longer in charge.
    expect(find.text('Preparando la asistencia...'), findsNothing);
    expect(find.byKey(SupportPanel.requestButtonKey), findsNothing);
    // The screen is not mentioned before there is an offer to answer, because
    // nothing has been captured and the user has not been asked for anything.
    expect(find.byKey(RemoteSessionPanel.screenCaptureLineKey), findsNothing);
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

  group('remote control line', () {
    Future<void> pumpLive(WidgetTester tester) async {
      await pumpAccepted(tester);
      remoteSessionRepository.currentResult = activeRemoteSession;
      remoteSessionBloc.add(const RemoteSessionSyncRequested());
      await settle(tester);
    }

    testWidgets('an enabled service is one line and no button', (tester) async {
      await pumpLive(tester);

      expect(find.text('Control remoto: habilitado'), findsOneWidget);
      expect(find.byKey(RemoteControlStatus.enableButtonKey), findsNothing);
    });

    testWidgets('CONNECTING does not claim control is enabled yet', (
      tester,
    ) async {
      await pumpAccepted(tester);
      remoteSessionRepository.currentResult = connectingRemoteSession;
      remoteSessionBloc.add(const RemoteSessionAnnounced(testRemoteSessionId));
      await settle(tester);

      expect(find.text('Control remoto: habilitado'), findsNothing);
      expect(
        find.text(
          'Control remoto: disponible cuando la asistencia esté activa',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a disabled service offers the way to Android settings', (
      tester,
    ) async {
      await pumpLive(tester);
      accessibility.pushStatus(RemoteControlAccessibilityStatus.unavailable);
      await settle(tester);

      expect(
        find.text('Control remoto: requiere habilitar accesibilidad'),
        findsOneWidget,
      );
      expect(find.text('HABILITAR CONTROL REMOTO'), findsOneWidget);

      await tester.tap(find.byKey(RemoteControlStatus.enableButtonKey));
      await settle(tester);

      // All it does is open the screen: the status moves only when Android says
      // the user enabled the service there.
      expect(accessibility.settingsOpened, 1);
      expect(
        find.text('Control remoto: requiere habilitar accesibilidad'),
        findsOneWidget,
      );

      accessibility.pushStatus(RemoteControlAccessibilityStatus.available);
      await settle(tester);

      expect(find.text('Control remoto: habilitado'), findsOneWidget);
      expect(find.byKey(RemoteControlStatus.enableButtonKey), findsNothing);
    });

    testWidgets('it is not shown before an assistance exists', (tester) async {
      await pumpAccepted(tester);

      expect(find.byKey(RemoteControlStatus.lineKey), findsNothing);
    });

    testWidgets('it says suspended while the tablet is reconnecting, even '
        'with the service enabled', (tester) async {
      await pumpLive(tester);
      expect(find.text('Control remoto: habilitado'), findsOneWidget);

      client.push(const RealtimeDisconnected());
      await settle(tester);

      expect(find.text('Control remoto: habilitado'), findsNothing);
      expect(
        find.text('Control remoto: suspendido hasta confirmar con el servidor'),
        findsOneWidget,
      );
    });

    testWidgets('back online, it stays suspended until the backend confirms', (
      tester,
    ) async {
      await pumpLive(tester);
      client.push(const RealtimeDisconnected());
      await settle(tester);

      // The socket is back but no read has been made since.
      client.push(const RealtimeConnected());
      await settle(tester);
      expect(find.text('Verificando la asistencia...'), findsOneWidget);
      expect(find.text('Control remoto: habilitado'), findsNothing);

      remoteSessionBloc.add(const RemoteSessionSyncRequested());
      await settle(tester);
      expect(find.text('Asistencia en curso'), findsOneWidget);
      expect(find.text('Control remoto: habilitado'), findsOneWidget);
    });

    testWidgets('Android stopping the capture withdraws it for good', (
      tester,
    ) async {
      await pumpLive(tester);
      await establishPeerConnection(tester);
      expect(find.text('Pantalla: compartiendo'), findsOneWidget);

      // The peer teardown that follows awaits real stream closes, which the
      // widget tester's fake clock does not drive on its own.
      await tester.runAsync(() async {
        screenCapture.endFromPlatform();
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      });
      await settle(tester);

      expect(find.text('Pantalla: Android detuvo la captura'), findsOneWidget);
      expect(find.text('Pantalla: compartiendo'), findsNothing);
      expect(
        find.text('Control remoto: deshabilitado en esta asistencia'),
        findsOneWidget,
      );
      expect(find.text('Control remoto: habilitado'), findsNothing);
      // The assistance can still be ended here.
      expect(find.byKey(RemoteSessionPanel.closeButtonKey), findsOneWidget);
    });
  });

  testWidgets('a connected peer with an open control channel says so', (
    tester,
  ) async {
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
    // The screen is a second, quieter line. It never replaces the headline:
    // the assistance is what the user is in, and sharing is one fact about it.
    expect(find.text('Pantalla: compartiendo'), findsOneWidget);
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

  testWidgets('a lost socket outranks an established peer connection', (
    tester,
  ) async {
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

  testWidgets('ACTIVE says the assistance is under way, and nothing more', (
    tester,
  ) async {
    await pumpAccepted(tester);

    remoteSessionRepository.currentResult = activeRemoteSession;
    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle(tester);

    expect(find.text('Asistencia en curso'), findsOneWidget);
    expect(find.text('Conectando con el técnico...'), findsNothing);
    expect(find.byKey(RemoteSessionPanel.closeButtonKey), findsOneWidget);
    // ACTIVE on its own says nothing about the screen: no offer was answered
    // here, so nothing was captured and nothing is claimed.
    expect(find.byKey(RemoteSessionPanel.screenCaptureLineKey), findsNothing);
  });

  testWidgets('a refused screen does not look like a broken session', (
    tester,
  ) async {
    await pumpAccepted(tester);
    screenCapture.result = const ScreenCaptureDenied();
    remoteSessionRepository.currentResult = connectingRemoteSession;
    remoteSessionBloc.add(const RemoteSessionAnnounced(testRemoteSessionId));
    await settle(tester);

    await establishPeerConnection(tester);

    // The technician is connected and the control channel is open. Declining
    // the Android dialog cost the screen and nothing else, and the headline
    // says exactly that.
    expect(find.text('Conexión remota establecida'), findsOneWidget);
    expect(find.text('Pantalla: permiso rechazado'), findsOneWidget);
    expect(find.byKey(RemoteSessionPanel.closeButtonKey), findsOneWidget);
  });

  testWidgets('a capture that failed says so, and no more than that', (
    tester,
  ) async {
    await pumpAccepted(tester);
    screenCapture.result = const ScreenCaptureUnavailable(
      ScreenCaptureFailure.captureRefused,
    );
    remoteSessionRepository.currentResult = connectingRemoteSession;
    remoteSessionBloc.add(const RemoteSessionAnnounced(testRemoteSessionId));
    await settle(tester);

    await establishPeerConnection(tester);

    expect(find.text('Pantalla: error al compartir'), findsOneWidget);
    // No reason, no code, no platform message. The user can do nothing with
    // any of those, and one of them could quote an Android exception.
    expect(find.textContaining('captureRefused'), findsNothing);
    expect(find.textContaining('MediaProjection'), findsNothing);
  });

  testWidgets('the wait for the Android dialog is visible', (tester) async {
    await pumpAccepted(tester);
    final gate = Completer<void>();
    screenCapture.startGate = gate;
    remoteSessionRepository.currentResult = connectingRemoteSession;
    remoteSessionBloc.add(const RemoteSessionAnnounced(testRemoteSessionId));
    await settle(tester);

    webRtcBloc.add(
      const WebRtcSignalingAvailabilityChanged(testRemoteSessionId),
    );
    webRtcBloc.add(const WebRtcRemoteSessionChanged(testRemoteSessionId));
    webRtcBloc.add(WebRtcOfferReceived(offerFor()));
    await settle(tester);

    // Android's own dialog is over the app at this moment; the line is what is
    // underneath it, and what is left if the user takes their time.
    expect(find.text('Pantalla: esperando autorización'), findsOneWidget);

    gate.complete();
    await settle(tester);
    expect(find.text('Pantalla: compartiendo'), findsOneWidget);
  });

  testWidgets('a reconnecting tablet says nothing about the screen', (
    tester,
  ) async {
    await pumpAccepted(tester);
    remoteSessionRepository.currentResult = connectingRemoteSession;
    remoteSessionBloc.add(const RemoteSessionAnnounced(testRemoteSessionId));
    await settle(tester);
    await establishPeerConnection(tester);
    expect(find.text('Pantalla: compartiendo'), findsOneWidget);

    client.push(const RealtimeDisconnected());
    await settle(tester);

    // The headline is already saying the connection is the problem. A second
    // line about a capture that is still running locally is not what the user
    // needs to read at that moment.
    expect(find.text('Reconectando...'), findsNWidgets(2));
    expect(find.byKey(RemoteSessionPanel.screenCaptureLineKey), findsNothing);
  });

  testWidgets('back online but unconfirmed, the screen reads paused, never '
      'shared', (tester) async {
    await pumpAccepted(tester);
    remoteSessionRepository.currentResult = connectingRemoteSession;
    remoteSessionBloc.add(const RemoteSessionAnnounced(testRemoteSessionId));
    await settle(tester);
    await establishPeerConnection(tester);
    expect(find.text('Pantalla: compartiendo'), findsOneWidget);

    client.push(const RealtimeDisconnected());
    await settle(tester);

    // The socket is back; no read has confirmed the session since.
    client.push(const RealtimeConnected());
    await settle(tester);
    expect(find.text('Verificando la asistencia...'), findsOneWidget);
    expect(
      find.text('Pantalla: en pausa hasta confirmar con el servidor'),
      findsOneWidget,
    );
    expect(find.text('Pantalla: compartiendo'), findsNothing);

    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle(tester);
    expect(find.text('Pantalla: compartiendo'), findsOneWidget);
  });

  testWidgets('CONNECTING becomes ACTIVE without contradicting itself', (
    tester,
  ) async {
    await pumpAccepted(tester);
    remoteSessionRepository.currentResult = connectingRemoteSession;
    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle(tester);
    expect(find.text('Conectando con el técnico...'), findsOneWidget);

    // WebRTC comes up first; the row follows when the technician reports it.
    await establishPeerConnection(tester);
    remoteSessionRepository.currentResult = activatedRemoteSession;
    remoteSessionBloc.add(
      const RemoteSessionActivationAnnounced(testRemoteSessionId),
    );
    await settle(tester);

    expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
    // The backend's word is the headline and the local reading supports it:
    // one story, not two contradicting lines.
    expect(find.text('Asistencia en curso'), findsOneWidget);
    expect(find.text('Conexión remota establecida'), findsOneWidget);
    expect(find.text('Conectando con el técnico...'), findsNothing);
    // The one action the user has is still there, and the peer connection was
    // not disturbed by the transition.
    expect(find.byKey(RemoteSessionPanel.closeButtonKey), findsOneWidget);
    expect(webRtcBloc.state.isRemoteConnectionEstablished, isTrue);
    expect(peerFactory.createCount, 1);
  });

  testWidgets('ACTIVE shows when the backend says the connection came up', (
    tester,
  ) async {
    await pumpAccepted(tester);

    remoteSessionRepository.currentResult = activatedRemoteSession;
    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle(tester);

    // Local time of the instant the backend wrote, formatted and nothing more:
    // no elapsed counter, and nothing shown when the field is absent.
    final connectedAt = activatedSession.connectedAt!.toLocal();
    final hour = connectedAt.hour.toString().padLeft(2, '0');
    final minute = connectedAt.minute.toString().padLeft(2, '0');
    expect(find.text('Conectado desde: $hour:$minute'), findsOneWidget);
  });

  testWidgets('a session with no connectedAt shows no connection time', (
    tester,
  ) async {
    await pumpAccepted(tester);

    // ACTIVE without the field: nothing is invented to fill the line.
    remoteSessionRepository.currentResult = activeRemoteSession;
    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle(tester);

    expect(find.text('Asistencia en curso'), findsOneWidget);
    expect(find.textContaining('Conectado desde'), findsNothing);
  });

  testWidgets('an ACTIVE session that loses the socket says reconnecting', (
    tester,
  ) async {
    await pumpAccepted(tester);
    remoteSessionRepository.currentResult = activatedRemoteSession;
    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle(tester);
    await establishPeerConnection(tester);
    expect(find.text('Conexión remota establecida'), findsOneWidget);

    client.push(const RealtimeDisconnected());
    await settle(tester);

    // The backend cannot reach the tablet, which outranks both the row and the
    // peer connection — and no line claims otherwise while it holds.
    expect(find.text('Asistencia en curso'), findsNothing);
    expect(find.text('Conexión remota establecida'), findsNothing);
    expect(find.textContaining('Conectado desde'), findsNothing);
    expect(webRtcBloc.state.isRemoteConnectionEstablished, isTrue);
  });

  testWidgets('losing the channel says reconnecting, never that it ended', (
    tester,
  ) async {
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
          .widget<OutlinedButton>(find.byKey(RemoteSessionPanel.closeButtonKey))
          .onPressed,
      isNotNull,
    );
    expect(find.byKey(SupportPanel.requestButtonKey), findsNothing);
  });

  group('authority recovery (Prompt 38)', () {
    testWidgets('a short loss that recovers leaves nothing alarming behind', (
      tester,
    ) async {
      await pumpAccepted(tester);
      remoteSessionRepository.currentResult = activatedRemoteSession;
      remoteSessionBloc.add(const RemoteSessionSyncRequested());
      await settle(tester);

      client.push(const RealtimeDisconnected());
      await settle(tester);
      timers.elapse(const Duration(seconds: 30));
      await settle(tester);
      client.push(const RealtimeConnected());
      await settle(tester);
      expect(find.text('Verificando la asistencia...'), findsOneWidget);
      remoteSessionBloc.add(const RemoteSessionSyncRequested());
      await settle(tester);

      expect(find.text('Asistencia en curso'), findsOneWidget);
      expect(find.text('Asistencia interrumpida'), findsNothing);
      expect(
        find.text(RemoteSessionEndedPanel.authorityLostMessage),
        findsNothing,
      );
      expect(find.byKey(RemoteSessionClosureNote.noteKey), findsNothing);
      expect(remoteSessionRepository.closeCount, 0);
    });

    testWidgets('a prolonged loss says it was the connection, offers no '
        'REINTENTAR, and sends nothing', (tester) async {
      await pumpAccepted(tester);
      remoteSessionRepository.currentResult = activatedRemoteSession;
      remoteSessionBloc.add(const RemoteSessionSyncRequested());
      await settle(tester);

      remoteSessionRepository.currentResult = remoteSessionUnreachable;
      client.push(const RealtimeDisconnected());
      await settle(tester);
      timers.elapse(RemoteSessionBloc.defaultAuthorityGracePeriod);
      await settle(tester);

      expect(find.text('Asistencia interrumpida'), findsOneWidget);
      expect(
        find.text(RemoteSessionEndedPanel.authorityLostMessage),
        findsOneWidget,
      );
      expect(
        find.text(RemoteSessionEndedPanel.authorityLostNextStep),
        findsOneWidget,
      );
      // Nothing reads like a FINALIZAR, and nothing offers to send one.
      expect(find.text('Asistencia finalizada'), findsNothing);
      expect(find.text('Finalizando la asistencia...'), findsNothing);
      expect(find.byKey(RemoteSessionEndedPanel.retryButtonKey), findsNothing);
      expect(find.byKey(RemoteSessionPanel.closeButtonKey), findsNothing);
      expect(remoteSessionRepository.closeCount, 0);

      // The backend closes it on its own; the tablet hears it on return.
      remoteSessionRepository.currentResult = noRemoteSession;
      supportRepository.currentResult = const Ok<SupportRequest?>(null);
      client.push(const RealtimeConnected());
      remoteSessionBloc.add(const RemoteSessionSyncRequested());
      supportBloc.add(const SupportSyncRequested());
      await settle(tester);

      expect(
        find.text(RemoteSessionClosureNote.interruptedMessage),
        findsOneWidget,
      );
      expect(find.byKey(SupportPanel.requestButtonKey), findsOneWidget);
      expect(remoteSessionRepository.closeCount, 0);
    });
  });

  testWidgets('ending it from the tablet closes and returns to the request', (
    tester,
  ) async {
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

  testWidgets(
    'pressing FINALIZAR ends it on screen before the server answers',
    (tester) async {
      await pumpAccepted(tester);
      remoteSessionRepository.currentResult = activatedRemoteSession;
      remoteSessionBloc.add(const RemoteSessionSyncRequested());
      await settle(tester);

      // The close is held open so the screen can be observed while it is in
      // flight.
      final gate = Completer<void>();
      remoteSessionRepository.closeGate = gate;
      remoteSessionRepository.currentQueue.add(noRemoteSession);

      await tester.tap(find.byKey(RemoteSessionPanel.closeButtonKey));
      await settle(tester);

      expect(find.text('Finalizando la asistencia...'), findsOneWidget);
      expect(
        find.text(
          'El técnico ya no puede controlar esta tablet ni ver su pantalla.',
        ),
        findsOneWidget,
      );
      // Nothing left to press, to share or to control: the live panel is gone,
      // which is also why a second press cannot start another close.
      expect(find.byKey(RemoteSessionPanel.closeButtonKey), findsNothing);
      expect(find.byKey(RemoteSessionPanel.screenCaptureLineKey), findsNothing);
      expect(find.byType(RemoteControlStatus), findsNothing);
      expect(find.byKey(RemoteSessionEndedPanel.retryButtonKey), findsNothing);

      gate.complete();
      await settle(tester);
      expect(remoteSessionRepository.closeCount, 1);
      expect(find.byType(RemoteSessionEndedPanel), findsNothing);
    },
  );

  testWidgets('a close the server could not confirm says so, and only that', (
    tester,
  ) async {
    await pumpAccepted(tester);
    remoteSessionRepository.currentResult = activatedRemoteSession;
    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle(tester);
    remoteSessionRepository.closeResult = closeUnreachable;

    await tester.tap(find.byKey(RemoteSessionPanel.closeButtonKey));
    await settle(tester);

    expect(find.text('Asistencia finalizada'), findsOneWidget);
    expect(
      find.text(RemoteSessionEndedPanel.unconfirmedMessage),
      findsOneWidget,
    );
    // Never "still sharing", never the live panel back.
    expect(find.byKey(RemoteSessionPanel.closeButtonKey), findsNothing);
    expect(find.textContaining('compartiendo'), findsNothing);
    expect(find.text('Asistencia en curso'), findsNothing);
    expect(find.byKey(SupportPanel.requestButtonKey), findsNothing);

    // REINTENTAR only tells the server again.
    remoteSessionRepository.closeResult = Ok(closedSession);
    remoteSessionRepository.currentResult = noRemoteSession;
    await tester.ensureVisible(
      find.byKey(RemoteSessionEndedPanel.retryButtonKey),
    );
    await tester.tap(find.byKey(RemoteSessionEndedPanel.retryButtonKey));
    await settle(tester);

    expect(remoteSessionRepository.closeCount, 2);
    expect(find.byType(RemoteSessionEndedPanel), findsNothing);
    expect(find.text('Asistencia en curso'), findsNothing);
  });

  testWidgets('an unknown session state offers to ask again, not to request', (
    tester,
  ) async {
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

  testWidgets('never shows a token, a secret or a backend message', (
    tester,
  ) async {
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
