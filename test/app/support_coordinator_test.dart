import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/app/support_coordinator.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/domain/entities/device_realtime_confirmation.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/check_device_status.dart';
import 'package:remote_control_device/features/device/domain/usecases/clear_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/accept_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/cancel_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/load_current_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/reject_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/request_support.dart';
import 'package:remote_control_device/features/support/presentation/bloc/support/support_bloc.dart';

import '../fakes/device_fakes.dart';
import '../fakes/realtime_fakes.dart';
import '../fakes/support_fakes.dart';

/// The blocs are real; only the socket, the secure store and the HTTP
/// repositories are faked. What is under test is the wiring: which facts make
/// the support state be re-read, and which make it be dropped.
void main() {
  late FakeDeviceRealtimeClient client;
  late FakeDeviceCredentialsStorage storage;
  late FakeDeviceAuthRepository authRepository;
  late FakeSupportRepository supportRepository;
  late DeviceTokenStore tokenStore;
  late DeviceSessionBloc sessionBloc;
  late DeviceRealtimeBloc realtimeBloc;
  late SupportBloc supportBloc;
  late SupportCoordinator coordinator;

  setUp(() {
    client = FakeDeviceRealtimeClient();
    storage = FakeDeviceCredentialsStorage(testCredentials);
    tokenStore = InMemoryDeviceTokenStore();
    authRepository = FakeDeviceAuthRepository(tokenStore: tokenStore);
    supportRepository = FakeSupportRepository();

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
    coordinator = SupportCoordinator(
      realtimeClient: client,
      realtimeBloc: realtimeBloc,
      sessionBloc: sessionBloc,
      supportBloc: supportBloc,
    )..start();
  });

  tearDown(() async {
    await coordinator.dispose();
    await supportBloc.close();
    await realtimeBloc.close();
    await sessionBloc.close();
  });

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> reachConnected() async {
    sessionBloc.add(const DeviceSessionStarted());
    await settle();
    // In the application this is `DeviceRealtimeCoordinator`'s job; only the
    // support wiring is under test here.
    realtimeBloc.add(const DeviceRealtimeStartRequested());
    await settle();
    await client.emit(const RealtimeConnected());
    await settle();
  }

  test('the support state is read as soon as the channel is up', () async {
    supportRepository.currentResult = const Ok<SupportRequest?>(waitingRequest);

    await reachConnected();

    expect(supportRepository.currentCount, 1);
    expect(supportBloc.state, isA<SupportWaiting>());
  });

  test('device:connected does not cause a second read', () async {
    await reachConnected();
    await client.emit(
      const RealtimeIdentityConfirmed(
        DeviceRealtimeConfirmation(
          deviceId: testDeviceId,
          publicId: testPublicId,
        ),
      ),
    );
    await settle();

    expect(supportRepository.currentCount, 1);
  });

  test('a reconnection reads it again, which is how a lost event is '
      'recovered', () async {
    await reachConnected();
    expect(supportBloc.state, const SupportIdle());

    // The tablet drops off the network. While it is away a technician takes the
    // request, so `support:assigned` is emitted to nobody.
    await client.emit(const RealtimeDisconnected());
    await settle();
    supportRepository.currentResult = const Ok<SupportRequest?>(assignedRequest);

    await client.emit(const RealtimeConnected());
    await settle();

    expect(supportRepository.currentCount, 2);
    expect(supportBloc.state, isA<SupportAssigned>());
  });

  test('support:assigned triggers the read, and the read decides', () async {
    await reachConnected();
    supportRepository.currentResult = const Ok<SupportRequest?>(assignedRequest);

    await client.emit(
      const RealtimeSupportAssigned(
        supportRequestId: testSupportRequestId,
        technicianId: testTechnicianId,
      ),
    );
    await settle();

    expect(supportRepository.currentCount, 2);
    expect(supportBloc.state, isA<SupportAssigned>());
    expect(
      (supportBloc.state as SupportAssigned).request.technician?.name,
      testTechnicianName,
    );
    // Never on the event's word alone.
    expect(supportRepository.acceptCount, 0);
  });

  test('a dropped connection leaves a pending request on screen', () async {
    supportRepository.currentResult = const Ok<SupportRequest?>(waitingRequest);
    await reachConnected();

    await client.emit(const RealtimeDisconnected());
    await settle();

    expect(supportBloc.state, isA<SupportWaiting>());
    expect(supportRepository.currentCount, 1);
  });

  test('a revoked credential clears the support state', () async {
    supportRepository.currentResult = const Ok<SupportRequest?>(assignedRequest);
    await reachConnected();
    expect(supportBloc.state, isA<SupportAssigned>());

    sessionBloc.add(const DeviceSessionCredentialRejected());
    await settle();

    expect(sessionBloc.state, const DeviceSessionReEnrollmentRequired());
    expect(supportBloc.state, const SupportInitial());
  });

  test('the coordinator stops listening once disposed', () async {
    await reachConnected();
    await coordinator.dispose();

    await client.emit(
      const RealtimeSupportAssigned(
        supportRequestId: testSupportRequestId,
        technicianId: testTechnicianId,
      ),
    );
    await settle();

    expect(supportRepository.currentCount, 1);
  });
}
