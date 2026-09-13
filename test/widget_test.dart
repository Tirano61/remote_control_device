import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/app/app_dependencies.dart';
import 'package:remote_control_device/app/remote_control_app.dart';
import 'package:remote_control_device/core/config/app_config.dart';
import 'package:remote_control_device/features/device/presentation/pages/ready_page.dart';

import 'fakes/device_fakes.dart';

void main() {
  const config = AppConfig(backendBaseUrl: 'http://backend.test:3000');

  testWidgets('a device with no credential lands on the enrollment form', (
    tester,
  ) async {
    // No HTTP happens on this path: the empty secure store short-circuits the
    // startup sequence before login.
    await tester.pumpWidget(
      RemoteControlApp(
        dependencies: AppDependencies.bootstrap(
          config: config,
          credentialsStorage: FakeDeviceCredentialsStorage(),
          deviceInfoProvider: FakeDeviceInfoProvider(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Activar dispositivo'), findsOneWidget);
    expect(find.text('Identificador del dispositivo'), findsOneWidget);
    expect(find.text('Código de activación'), findsOneWidget);
    expect(find.text('Activar'), findsOneWidget);
  });

  testWidgets('the ready screen shows public data only', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ReadyPage(device: testIdentity)),
    );

    expect(find.text('ASISTENCIA REMOTA'), findsOneWidget);
    expect(find.text(testPublicId), findsOneWidget);
    expect(find.text(testDeviceName), findsOneWidget);
    expect(find.text('Listo'), findsOneWidget);
    expect(find.text('Dispositivo listo'), findsOneWidget);

    // Neither the permanent credential nor the Device JWT may ever be shown.
    expect(find.textContaining(testDeviceSecret), findsNothing);
    expect(find.textContaining(testDeviceJwt), findsNothing);

    // "Solicitar asistencia" belongs to a later prompt.
    expect(find.text('Solicitar asistencia'), findsNothing);
  });
}
