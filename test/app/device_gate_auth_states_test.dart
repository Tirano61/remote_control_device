import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/app/app_dependencies.dart';
import 'package:remote_control_device/app/device_gate.dart';
import 'package:remote_control_device/core/config/app_config.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/check_device_status.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/suspend_device_authorization.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';

import '../fakes/device_fakes.dart';
import '../fakes/manual_timers.dart';
import '../fakes/realtime_fakes.dart';
import '../fakes/remote_session_fakes.dart';

/// What the user sees in each authentication state, and what each button does.
void main() {
  const config = AppConfig(backendBaseUrl: 'http://backend.test:3000');

  late FakeDeviceCredentialsStorage storage;
  late FakeDeviceAuthRepository authRepository;
  late ManualTimers timers;
  late DeviceSessionBloc sessionBloc;

  Future<void> pumpGate(WidgetTester tester) async {
    sessionBloc = DeviceSessionBloc(
      loadDeviceCredentials: LoadDeviceCredentials(storage),
      authenticateDevice: AuthenticateDevice(authRepository),
      checkDeviceStatus: CheckDeviceStatus(authRepository),
      suspendDeviceAuthorization: SuspendDeviceAuthorization(authRepository),
      timerFactory: timers.factory,
    );
    // Only the enrollment use case is reached through these, and only if the
    // form is submitted, which no test here does.
    final dependencies = AppDependencies.bootstrap(
      config: config,
      credentialsStorage: storage,
      endedRemoteSessionStore: FakeEndedRemoteSessionStore(),
      deviceInfoProvider: FakeDeviceInfoProvider(),
      realtimeChannel: FakeDeviceRealtimeClient(),
    );
    await tester.pumpWidget(
      BlocProvider.value(
        value: sessionBloc,
        child: MaterialApp(home: DeviceGate(dependencies: dependencies)),
      ),
    );
    sessionBloc.add(const DeviceSessionStarted());
    await tester.pumpAndSettle();
  }

  setUp(() {
    storage = FakeDeviceCredentialsStorage(testCredentials);
    authRepository = FakeDeviceAuthRepository(
      tokenStore: InMemoryDeviceTokenStore(),
    );
    timers = ManualTimers();
  });

  tearDown(() => sessionBloc.close());

  testWidgets('a refusal says so and offers retry and re-activation, '
      'not the enrollment form', (tester) async {
    authRepository.loginResult = loginRejected;
    await pumpGate(tester);

    expect(find.text('Autenticación rechazada'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
    expect(find.text('Activar de nuevo'), findsOneWidget);
    expect(find.text('Activar dispositivo'), findsNothing);
  });

  // Reactivation → READY is pinned in device_session_bloc_test; the ready
  // screen needs the whole app around it.
  testWidgets('retry asks the backend once more and stays refused if it '
      'still refuses', (tester) async {
    authRepository.loginResult = loginRejected;
    await pumpGate(tester);
    expect(authRepository.loginCount, 1);

    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();

    expect(authRepository.loginCount, 2);
    expect(find.text('Autenticación rechazada'), findsOneWidget);
    expect(storage.credentials, testCredentials);
    expect(timers.pending, isEmpty);
  });

  testWidgets('re-activation warns that it replaces the stored enrollment and '
      'can be cancelled', (tester) async {
    authRepository.loginResult = loginRejected;
    await pumpGate(tester);

    await tester.tap(find.text('Activar de nuevo'));
    await tester.pumpAndSettle();

    expect(find.text('Activar dispositivo'), findsOneWidget);
    expect(
      find.textContaining('reemplaza la activación guardada'),
      findsOneWidget,
    );
    expect(
      find.textContaining('se conserva hasta que la nueva se complete'),
      findsOneWidget,
    );
    expect(storage.credentials, testCredentials);

    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    expect(find.text('Autenticación rechazada'), findsOneWidget);
    expect(storage.credentials, testCredentials);
    expect(storage.clearCount, 0);
  });

  testWidgets('a first enrollment has no warning and no way out', (
    tester,
  ) async {
    storage.credentials = null;
    await pumpGate(tester);

    expect(find.text('Activar dispositivo'), findsOneWidget);
    expect(find.text('Cancelar'), findsNothing);
    expect(find.textContaining('reemplaza'), findsNothing);
  });

  testWidgets('an ambiguous 401 shows "unavailable", never asks to enroll', (
    tester,
  ) async {
    authRepository.loginResult = loginUnauthorized;
    await pumpGate(tester);

    expect(find.text('Autenticación no disponible'), findsOneWidget);
    expect(find.text('Se reintentará automáticamente.'), findsOneWidget);
    expect(find.text('Activar dispositivo'), findsNothing);
    expect(find.text('Activar de nuevo'), findsNothing);
    expect(find.textContaining('volver a activarse'), findsNothing);
  });
}
