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

import 'fakes/device_fakes.dart';
import 'fakes/realtime_fakes.dart';

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

    setUp(() => client = FakeDeviceRealtimeClient());

    tearDown(() => realtimeBloc.close());

    // The bloc is built here rather than in setUp so that it lives inside the
    // test's async zone; one created outside it would never deliver a state.
    Future<void> pumpReadyPage(WidgetTester tester) {
      final storage = FakeDeviceCredentialsStorage(testCredentials);
      realtimeBloc = DeviceRealtimeBloc(
        client: client,
        tokenStore: InMemoryDeviceTokenStore()..save(testDeviceJwt),
        renewDeviceToken: RenewDeviceToken(
          loadDeviceCredentials: LoadDeviceCredentials(storage),
          authenticateDevice: AuthenticateDevice(FakeDeviceAuthRepository()),
        ),
      );
      return tester.pumpWidget(
        BlocProvider<DeviceRealtimeBloc>.value(
          value: realtimeBloc,
          child: const MaterialApp(home: ReadyPage(device: testIdentity)),
        ),
      );
    }

    testWidgets('shows public data only', (tester) async {
      await pumpReadyPage(tester);

      expect(find.text('ASISTENCIA REMOTA'), findsOneWidget);
      expect(find.text(testPublicId), findsOneWidget);
      expect(find.text(testDeviceName), findsOneWidget);
      expect(find.text('Listo'), findsOneWidget);

      // Neither the permanent credential nor the Device JWT may ever be shown.
      expect(find.textContaining(testDeviceSecret), findsNothing);
      expect(find.textContaining(testDeviceJwt), findsNothing);

      // "Solicitar asistencia" belongs to a later prompt.
      expect(find.text('Solicitar asistencia'), findsNothing);
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
