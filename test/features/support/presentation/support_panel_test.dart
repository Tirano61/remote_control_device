import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/accept_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/cancel_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/load_current_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/reject_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/request_support.dart';
import 'package:remote_control_device/features/support/presentation/bloc/support/support_bloc.dart';
import 'package:remote_control_device/features/support/presentation/widgets/support_panel.dart';

import '../../../fakes/device_fakes.dart';
import '../../../fakes/realtime_fakes.dart';
import '../../../fakes/support_fakes.dart';

void main() {
  late FakeSupportRepository repository;
  late FakeDeviceRealtimeClient client;
  late InMemoryDeviceTokenStore tokenStore;
  late SupportBloc supportBloc;
  late DeviceRealtimeBloc realtimeBloc;

  /// Built inside the test body on purpose.
  ///
  /// A bloc created in `setUp` lives in a different zone from the one
  /// `testWidgets` drives, and `pump` would never run its continuations: the
  /// screen would sit on its initial state forever.
  void createBlocs() {
    repository = FakeSupportRepository();
    client = FakeDeviceRealtimeClient();
    tokenStore = InMemoryDeviceTokenStore()..save(testDeviceJwt);

    supportBloc = SupportBloc(
      requestSupport: RequestSupport(repository),
      loadCurrentSupportRequest: LoadCurrentSupportRequest(repository),
      acceptSupportRequest: AcceptSupportRequest(repository),
      rejectSupportRequest: RejectSupportRequest(repository),
      cancelSupportRequest: CancelSupportRequest(repository),
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
    addTearDown(supportBloc.close);
    addTearDown(realtimeBloc.close);
  }

  Widget harness() => MultiBlocProvider(
    providers: [
      BlocProvider<SupportBloc>.value(value: supportBloc),
      BlocProvider<DeviceRealtimeBloc>.value(value: realtimeBloc),
    ],
    child: const MaterialApp(home: Scaffold(body: SupportPanel())),
  );

  /// Lets queued bloc events, their awaited calls and the rebuild that follows
  /// all complete.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(Duration.zero);
    }
  }

  /// Brings the realtime channel up, the way the coordinators do in the app.
  Future<void> connect(WidgetTester tester) async {
    realtimeBloc.add(const DeviceRealtimeStartRequested());
    client.push(const RealtimeConnected());
    await settle(tester);
  }

  Future<void> syncTo(WidgetTester tester, SupportRequest? request) async {
    repository.currentResult = Ok<SupportRequest?>(request);
    supportBloc.add(const SupportSyncRequested());
    await settle(tester);
  }

  testWidgets('a ready, connected device with no request can ask for help', (
    tester,
  ) async {
    createBlocs();
    await tester.pumpWidget(harness());
    await connect(tester);
    await syncTo(tester, null);

    final button = tester.widget<FilledButton>(
      find.byKey(SupportPanel.requestButtonKey),
    );
    expect(button.onPressed, isNotNull);

    await tester.tap(find.byKey(SupportPanel.requestButtonKey));
    await settle(tester);

    expect(repository.createCount, 1);
    expect(find.text('Esperando a un técnico...'), findsOneWidget);
  });

  testWidgets('a disconnected device cannot start a request', (tester) async {
    createBlocs();
    await tester.pumpWidget(harness());
    await syncTo(tester, null);

    // The backend only lets a technician take a request from a device it sees
    // as ONLINE, and presence is this socket.
    final button = tester.widget<FilledButton>(
      find.byKey(SupportPanel.requestButtonKey),
    );
    expect(button.onPressed, isNull);
    expect(find.textContaining('Conectando al servicio'), findsOneWidget);

    await tester.tap(
      find.byKey(SupportPanel.requestButtonKey),
      warnIfMissed: false,
    );
    await settle(tester);

    expect(repository.createCount, 0);
  });

  testWidgets('a double tap sends one request', (tester) async {
    createBlocs();
    await tester.pumpWidget(harness());
    await connect(tester);
    await syncTo(tester, null);

    await tester.tap(find.byKey(SupportPanel.requestButtonKey));
    await tester.tap(
      find.byKey(SupportPanel.requestButtonKey),
      warnIfMissed: false,
    );
    await settle(tester);

    expect(repository.createCount, 1);
  });

  testWidgets('a WAITING request offers to withdraw it', (tester) async {
    createBlocs();
    await tester.pumpWidget(harness());
    await connect(tester);
    await syncTo(tester, waitingRequest);

    expect(find.text('Solicitud enviada'), findsOneWidget);
    expect(find.byKey(SupportPanel.requestButtonKey), findsNothing);

    await tester.tap(find.byKey(SupportPanel.cancelButtonKey));
    await settle(tester);

    expect(repository.cancelCount, 1);
    expect(find.byKey(SupportPanel.requestButtonKey), findsOneWidget);
  });

  testWidgets('an ASSIGNED request asks the user, and waits for the answer', (
    tester,
  ) async {
    createBlocs();
    await tester.pumpWidget(harness());
    await connect(tester);
    await syncTo(tester, assignedRequest);

    expect(find.textContaining(testTechnicianName), findsOneWidget);
    expect(find.text('¿Desea permitir la asistencia?'), findsOneWidget);
    expect(find.byKey(SupportPanel.acceptButtonKey), findsOneWidget);
    expect(find.byKey(SupportPanel.rejectButtonKey), findsOneWidget);
    // Showing the prompt authorises nothing on its own.
    expect(repository.acceptCount, 0);
  });

  group('the disclosure before PERMITIR', () {
    /// Everything the disclosure says, so the checks below ask what it conveys
    /// and not how one sentence is worded.
    String disclosure(WidgetTester tester) => tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(SupportPanel.controlDisclosureKey),
            matching: find.byType(Text),
          ),
        )
        .map((text) => text.data ?? '')
        .join(' ')
        .toLowerCase();

    testWidgets('says what the technician can do, text input included', (
      tester,
    ) async {
      createBlocs();
      await tester.pumpWidget(harness());
      await connect(tester);
      await syncTo(tester, assignedRequest);

      final said = disclosure(tester);
      expect(said, contains('pantalla'));
      expect(said, contains('tocar'));
      expect(said, contains('deslizar'));
      expect(said, contains('atrás'));
      expect(said, contains('inicio'));
      expect(said, contains('recientes'));
      expect(said, contains('introducir texto'));
      expect(said, contains('campo'));
      expect(said, contains('seleccionado'));
      expect(said, contains('reemplaza'));
    });

    testWidgets('says what the system does not do, and for how long', (
      tester,
    ) async {
      createBlocs();
      await tester.pumpWidget(harness());
      await connect(tester);
      await syncTo(tester, assignedRequest);

      final said = disclosure(tester);
      expect(said, contains('durante esta asistencia'));
      expect(said, contains('no envía'));
      expect(said, contains('contenido actual'));
      expect(said, contains('de forma continua'));
      expect(said, contains('fuera de una asistencia'));
      // The picture does show what a field displays. Saying the content never
      // reaches the technician without that exception would be false.
      expect(said, contains('se vea en la pantalla compartida'));
    });

    testWidgets('promises nothing about passwords and names nothing internal', (
      tester,
    ) async {
      createBlocs();
      await tester.pumpWidget(harness());
      await connect(tester);
      await syncTo(tester, assignedRequest);

      final said = disclosure(tester);
      // A password field takes a set_text like any other field.
      expect(said, isNot(contains('contraseña')));
      for (final internal in const [
        'accessibilitynodeinfo',
        'focus_input',
        'action_set_text',
        'canretrievewindowcontent',
        'set_text',
      ]) {
        expect(said, isNot(contains(internal)));
      }
    });

    testWidgets('is on screen above the buttons, and decides nothing', (
      tester,
    ) async {
      createBlocs();
      await tester.pumpWidget(harness());
      await connect(tester);
      await syncTo(tester, assignedRequest);

      final bottom = tester
          .getBottomLeft(find.byKey(SupportPanel.controlDisclosureKey))
          .dy;
      expect(
        bottom,
        lessThan(
          tester.getTopLeft(find.byKey(SupportPanel.acceptButtonKey)).dy,
        ),
      );
      expect(
        bottom,
        lessThan(
          tester.getTopLeft(find.byKey(SupportPanel.rejectButtonKey)).dy,
        ),
      );
      expect(find.byType(Tooltip), findsNothing);
      // No second consent to tick: PERMITIR is the one answer.
      expect(find.byType(Checkbox), findsNothing);

      // Reading it for as long as it takes changes nothing.
      await tester.pump(const Duration(minutes: 10));
      await settle(tester);
      expect(repository.acceptCount, 0);
      expect(repository.rejectCount, 0);
      expect(find.byKey(SupportPanel.acceptButtonKey), findsOneWidget);
    });

    testWidgets('belongs to the prompt, not to the states around it', (
      tester,
    ) async {
      createBlocs();
      await tester.pumpWidget(harness());
      await connect(tester);

      await syncTo(tester, null);
      expect(find.byKey(SupportPanel.controlDisclosureKey), findsNothing);

      await syncTo(tester, waitingRequest);
      expect(find.byKey(SupportPanel.controlDisclosureKey), findsNothing);

      await syncTo(tester, assignedRequest);
      expect(find.byKey(SupportPanel.controlDisclosureKey), findsOneWidget);

      await tester.tap(find.byKey(SupportPanel.acceptButtonKey));
      await settle(tester);
      expect(find.byKey(SupportPanel.controlDisclosureKey), findsNothing);
    });
  });

  testWidgets('PERMITIR is what authorises the technician', (tester) async {
    createBlocs();
    await tester.pumpWidget(harness());
    await connect(tester);
    await syncTo(tester, assignedRequest);

    await tester.tap(find.byKey(SupportPanel.acceptButtonKey));
    await settle(tester);

    expect(repository.acceptCount, 1);
    expect(find.text('Técnico autorizado'), findsOneWidget);
    // Still no remote session, and nothing captured: the technician creates it.
    expect(find.byKey(SupportPanel.cancelButtonKey), findsOneWidget);
  });

  testWidgets('RECHAZAR leaves no technician authorised', (tester) async {
    createBlocs();
    await tester.pumpWidget(harness());
    await connect(tester);
    await syncTo(tester, assignedRequest);

    await tester.tap(find.byKey(SupportPanel.rejectButtonKey));
    await settle(tester);

    expect(repository.rejectCount, 1);
    expect(repository.acceptCount, 0);
    expect(find.byKey(SupportPanel.requestButtonKey), findsOneWidget);
  });

  testWidgets('CANCELAR still withdraws after PERMITIR', (tester) async {
    createBlocs();
    await tester.pumpWidget(harness());
    await connect(tester);
    await syncTo(tester, assignedRequest);

    await tester.tap(find.byKey(SupportPanel.acceptButtonKey));
    await settle(tester);
    await tester.tap(find.byKey(SupportPanel.cancelButtonKey));
    await settle(tester);

    expect(repository.cancelCount, 1);
    expect(find.byKey(SupportPanel.requestButtonKey), findsOneWidget);
  });

  testWidgets('a state that could not be read is not shown as "no request"', (
    tester,
  ) async {
    createBlocs();
    repository.currentResult = currentUnreachable;
    await tester.pumpWidget(harness());
    await connect(tester);
    supportBloc.add(const SupportSyncRequested());
    await settle(tester);

    expect(find.byKey(SupportPanel.requestButtonKey), findsNothing);
    expect(find.byKey(SupportPanel.retryButtonKey), findsOneWidget);
  });
}
