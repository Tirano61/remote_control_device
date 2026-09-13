import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/app/app_dependencies.dart';
import 'package:remote_control_device/app/remote_control_app.dart';
import 'package:remote_control_device/core/config/app_config.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/domain/entities/device_realtime_confirmation.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/pages/ready_page.dart';
import 'package:remote_control_device/features/support/domain/usecases/accept_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/cancel_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/load_current_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/reject_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/request_support.dart';
import 'package:remote_control_device/features/support/presentation/bloc/support/support_bloc.dart';
import 'package:remote_control_device/features/support/presentation/widgets/support_panel.dart';

import 'fakes/device_fakes.dart';
import 'fakes/realtime_fakes.dart';
import 'fakes/support_fakes.dart';

void main() {
  const config = AppConfig(backendBaseUrl: 'http://backend.test:3000');

  testWidgets('a device with no credential lands on the enrollment form', (
    tester,
  ) async {
    // No HTTP and no socket happen on this path: the empty secure store
    // short-circuits the startup sequence before login.
    final realtimeClient = FakeDeviceRealtimeClient();
    await tester.pumpWidget(
      RemoteControlApp(
        dependencies: AppDependencies.bootstrap(
          config: config,
          credentialsStorage: FakeDeviceCredentialsStorage(),
          deviceInfoProvider: FakeDeviceInfoProvider(),
          realtimeClient: realtimeClient,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Activar dispositivo'), findsOneWidget);
    expect(find.text('Identificador del dispositivo'), findsOneWidget);
    expect(find.text('Código de activación'), findsOneWidget);
    expect(find.text('Activar'), findsOneWidget);
    expect(realtimeClient.connectedWithTokens, isEmpty);
  });

  group('ready screen', () {
    late FakeDeviceRealtimeClient client;
    late DeviceRealtimeBloc realtimeBloc;
    late SupportBloc supportBloc;

    setUp(() => client = FakeDeviceRealtimeClient());

    tearDown(() async {
      await realtimeBloc.close();
      await supportBloc.close();
    });

    // The blocs are built here rather than in setUp so that they live inside
    // the test's async zone; ones created outside it would never deliver a
    // state.
    Future<void> pumpReadyPage(WidgetTester tester) async {
      final storage = FakeDeviceCredentialsStorage(testCredentials);
      realtimeBloc = DeviceRealtimeBloc(
        client: client,
        tokenStore: InMemoryDeviceTokenStore()..save(testDeviceJwt),
        renewDeviceToken: RenewDeviceToken(
          loadDeviceCredentials: LoadDeviceCredentials(storage),
          authenticateDevice: AuthenticateDevice(FakeDeviceAuthRepository()),
        ),
      );
      // Answers "no active request", which is the screen this group is about.
      final supportRepository = FakeSupportRepository();
      supportBloc = SupportBloc(
        requestSupport: RequestSupport(supportRepository),
        loadCurrentSupportRequest: LoadCurrentSupportRequest(supportRepository),
        acceptSupportRequest: AcceptSupportRequest(supportRepository),
        rejectSupportRequest: RejectSupportRequest(supportRepository),
        cancelSupportRequest: CancelSupportRequest(supportRepository),
      );

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<DeviceRealtimeBloc>.value(value: realtimeBloc),
            BlocProvider<SupportBloc>.value(value: supportBloc),
          ],
          child: const MaterialApp(home: ReadyPage(device: testIdentity)),
        ),
      );
      supportBloc.add(const SupportSyncRequested());
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
    }

    testWidgets('shows public data only', (tester) async {
      await pumpReadyPage(tester);

      expect(find.text('ASISTENCIA REMOTA'), findsOneWidget);
      expect(find.text(testPublicId), findsOneWidget);
      expect(find.text(testDeviceName), findsOneWidget);

      // Neither the permanent credential nor the Device JWT may ever be shown.
      expect(find.textContaining(testDeviceSecret), findsNothing);
      expect(find.textContaining(testDeviceJwt), findsNothing);
    });

    testWidgets('offers assistance only once the channel is up', (tester) async {
      await pumpReadyPage(tester);

      // The button is on screen from the start, so the user can see what the
      // device is for — but it does nothing until the backend can see this
      // device as ONLINE.
      expect(
        tester
            .widget<FilledButton>(find.byKey(SupportPanel.requestButtonKey))
            .onPressed,
        isNull,
      );

      realtimeBloc.add(const DeviceRealtimeStartRequested());
      client.push(const RealtimeConnected());
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);

      expect(
        tester
            .widget<FilledButton>(find.byKey(SupportPanel.requestButtonKey))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('reports the realtime channel in plain words', (tester) async {
      await pumpReadyPage(tester);
      expect(find.text('Sin conexión'), findsOneWidget);

      realtimeBloc.add(const DeviceRealtimeStartRequested());
      await tester.pumpAndSettle();
      expect(find.text('Conectando...'), findsOneWidget);

      client.push(const RealtimeConnected());
      await tester.pumpAndSettle();
      expect(find.text('Conectado'), findsOneWidget);

      client.push(
        const RealtimeIdentityConfirmed(
          DeviceRealtimeConfirmation(
            deviceId: testDeviceId,
            publicId: testPublicId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Conectado'), findsOneWidget);

      client.push(const RealtimeDisconnected());
      await tester.pumpAndSettle();
      expect(find.text('Reconectando...'), findsOneWidget);
    });

    testWidgets('never shows the technical reason a connection failed', (
      tester,
    ) async {
      await pumpReadyPage(tester);
      realtimeBloc.add(const DeviceRealtimeStartRequested());
      await tester.pumpAndSettle();
      client.push(const RealtimeConnectFailed());
      await tester.pumpAndSettle();

      expect(find.text('Sin conexión'), findsOneWidget);
      expect(find.textContaining('Unauthorized'), findsNothing);
      expect(find.textContaining('Socket'), findsNothing);
      expect(find.textContaining('JWT'), findsNothing);
      expect(find.textContaining('error'), findsNothing);
    });
  });
}
