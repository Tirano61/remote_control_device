import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/app/device_realtime_coordinator.dart';
import 'package:remote_control_device/app/remote_session_coordinator.dart';
import 'package:remote_control_device/app/support_coordinator.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/core/session/device_credential_revocation.dart';
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
import 'package:remote_control_device/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/accept_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/cancel_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/load_current_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/reject_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/request_support.dart';
import 'package:remote_control_device/features/support/presentation/bloc/support/support_bloc.dart';

import '../fakes/device_fakes.dart';
import '../fakes/realtime_fakes.dart';
import '../fakes/remote_session_fakes.dart';
import '../fakes/support_fakes.dart';

/// The blocs are real; only the socket, the secure store and the HTTP
/// repositories are faked. What is under test is the wiring: which facts make
/// the remote session be re-read, which make it be dropped, and what a session
/// that ended does to the support request.
///
/// Both coordinators run, because in the application they always do: the
/// interesting cases are precisely the ones where the two features have to end
/// up agreeing.
void main() {
  late FakeDeviceRealtimeClient client;
  late FakeDeviceCredentialsStorage storage;
  late FakeDeviceAuthRepository authRepository;
  late FakeSupportRepository supportRepository;
  late FakeRemoteSessionRepository remoteSessionRepository;
  late DeviceTokenStore tokenStore;
  late DeviceSessionBloc sessionBloc;
  late DeviceRealtimeBloc realtimeBloc;
  late SupportBloc supportBloc;
  late RemoteSessionBloc remoteSessionBloc;
  late DeviceCredentialRevocation credentialRevocation;
  late DeviceRealtimeCoordinator realtimeCoordinator;
  late SupportCoordinator supportCoordinator;
  late RemoteSessionCoordinator coordinator;

  setUp(() {
    client = FakeDeviceRealtimeClient();
    storage = FakeDeviceCredentialsStorage(testCredentials);
    tokenStore = InMemoryDeviceTokenStore();
    authRepository = FakeDeviceAuthRepository(tokenStore: tokenStore);
    supportRepository = FakeSupportRepository();
    remoteSessionRepository = FakeRemoteSessionRepository();
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
    coordinator = RemoteSessionCoordinator(
      realtimeClient: client,
      realtimeBloc: realtimeBloc,
      sessionBloc: sessionBloc,
      supportBloc: supportBloc,
      remoteSessionBloc: remoteSessionBloc,
    )..start();
  });

  tearDown(() async {
    await coordinator.dispose();
    await supportCoordinator.dispose();
    await realtimeCoordinator.dispose();
    await credentialRevocation.dispose();
    await remoteSessionBloc.close();
    await supportBloc.close();
    await realtimeBloc.close();
    await sessionBloc.close();
  });

  Future<void> settle() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// The device is authenticated and its socket is up — the state from which
  /// every scenario below starts.
  Future<void> reachConnected() async {
    sessionBloc.add(const DeviceSessionStarted());
    await settle();
    // In the application this is `DeviceRealtimeCoordinator`'s job; only the
    // remote-session wiring is under test here.
    // `DeviceRealtimeCoordinator` opens the channel once the session is READY;
    // the explicit start here only makes the ordering visible.
    realtimeBloc.add(const DeviceRealtimeStartRequested());
    await settle();
    await client.emit(const RealtimeConnected());
    await settle();
  }

  test('the session is read as soon as the channel is up — which is also the '
      'whole restart story', () async {
    // A session created while the application was not running: nothing
    // announces it, and the first arrival at connected finds it anyway.
    remoteSessionRepository.currentResult = connectingRemoteSession;

    await reachConnected();

    expect(remoteSessionRepository.currentCount, 1);
    expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
  });

  test('accepting a technician asks whether a session exists yet', () async {
    supportRepository.currentResult = const Ok<SupportRequest?>(assignedRequest);
    await reachConnected();
    expect(remoteSessionRepository.currentCount, 1);

    // The user presses PERMITIR. There is no session yet — the normal case.
    supportBloc.add(const SupportAcceptRequested());
    await settle();

    expect(supportBloc.state, isA<SupportAccepted>());
    expect(remoteSessionRepository.currentCount, 2);
    expect(remoteSessionBloc.state, const RemoteSessionIdle());
  });

  test('an ACCEPTED request re-emitted for other reasons does not re-read',
      () async {
    supportRepository.currentResult = const Ok<SupportRequest?>(assignedRequest);
    await reachConnected();
    supportBloc.add(const SupportAcceptRequested());
    await settle();
    final reads = remoteSessionRepository.currentCount;

    // A cancel that fails leaves the request ACCEPTED with a failure note: the
    // state changes, the authorisation does not.
    supportRepository.cancelResult = supportUnreachable;
    supportBloc.add(const SupportCancelRequested());
    await settle();

    expect(supportBloc.state, isA<SupportAccepted>());
    expect(remoteSessionRepository.currentCount, reads);
  });

  test('remote-session:created triggers the read, and the read decides',
      () async {
    await reachConnected();
    remoteSessionRepository.currentResult = connectingRemoteSession;

    await client.emit(
      const RealtimeRemoteSessionCreated(
        remoteSessionId: testRemoteSessionId,
        supportRequestId: testSupportRequestId,
        technicianId: testTechnicianId,
      ),
    );
    await settle();

    expect(remoteSessionRepository.currentCount, 2);
    final state = remoteSessionBloc.state;
    expect(state, isA<RemoteSessionConnecting>());
    // Built from the REST payload, never from the event.
    expect((state as RemoteSessionConnecting).session, connectingSession);
  });

  test('remote-session:active triggers the read that moves it to ACTIVE',
      () async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    supportRepository.currentResult = const Ok<SupportRequest?>(acceptedRequest);
    await reachConnected();
    expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
    final supportReads = supportRepository.currentCount;
    final reads = remoteSessionRepository.currentCount;

    // The technician's browser reported the connection with
    // POST /remote-sessions/:id/activate; the backend committed ACTIVE and
    // announced it. The tablet never calls /activate itself.
    remoteSessionRepository.currentResult = activatedRemoteSession;
    await client.emit(
      const RealtimeRemoteSessionActivated(testRemoteSessionId),
    );
    await settle();

    expect(remoteSessionRepository.currentCount, reads + 1);
    final state = remoteSessionBloc.state;
    expect(state, isA<RemoteSessionActive>());
    // Built from the REST payload, never from the event — which carries no
    // status and no timestamp at all.
    expect((state as RemoteSessionActive).session, activatedSession);
    // And the assistance goes on being the same assistance: the session stayed
    // live throughout, so the support request is not re-read and the screen
    // never falls back to it.
    expect(supportRepository.currentCount, supportReads);
    expect(supportBloc.state, isA<SupportAccepted>());
  });

  test('a repeated remote-session:active on an ACTIVE session does nothing',
      () async {
    remoteSessionRepository.currentResult = activatedRemoteSession;
    await reachConnected();
    expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
    final reads = remoteSessionRepository.currentCount;
    final state = remoteSessionBloc.state;

    await client.emit(
      const RealtimeRemoteSessionActivated(testRemoteSessionId),
    );
    await client.emit(
      const RealtimeRemoteSessionActivated(testRemoteSessionId),
    );
    await settle();

    // No read, no loop, and the state is the very same object.
    expect(remoteSessionRepository.currentCount, reads);
    expect(remoteSessionBloc.state, same(state));
  });

  test('an activation announced for another session is ignored', () async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    await reachConnected();

    await client.emit(
      const RealtimeRemoteSessionActivated(testOtherRemoteSessionId),
    );
    await settle();

    // Not read, not adopted: a realtime payload never moves ownership, and the
    // session on screen is still the one REST gave.
    expect(remoteSessionRepository.currentCount, 1);
    final state = remoteSessionBloc.state;
    expect(state, isA<RemoteSessionConnecting>());
    expect((state as RemoteSessionConnecting).session.id, testRemoteSessionId);
  });

  test('an activation that never arrived is recovered by reconnecting',
      () async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    await reachConnected();
    expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());

    // The tablet drops off the network. While it is away the technician's
    // /activate commits and remote-session:active is emitted to nobody:
    // delivery is best-effort and nothing is replayed.
    await client.emit(const RealtimeDisconnected());
    await settle();
    remoteSessionRepository.currentResult = activatedRemoteSession;

    await client.emit(const RealtimeConnected());
    await settle();

    // The same read every reconnection makes finds ACTIVE. This is also the
    // restart path: a fresh application reaches connected once and lands here.
    expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
    expect(
      (remoteSessionBloc.state as RemoteSessionActive).session.connectedAt,
      isNotNull,
    );
  });

  test('a reconnection reads it again, which is how a lost event is recovered',
      () async {
    await reachConnected();
    expect(remoteSessionBloc.state, const RemoteSessionIdle());

    // The tablet drops off the network. While it is away the technician starts
    // the assistance, so remote-session:created is emitted to nobody.
    await client.emit(const RealtimeDisconnected());
    await settle();
    remoteSessionRepository.currentResult = connectingRemoteSession;

    await client.emit(const RealtimeConnected());
    await settle();

    expect(remoteSessionRepository.currentCount, 2);
    expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
  });

  test('a dropped connection leaves a live session on screen', () async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    await reachConnected();

    await client.emit(const RealtimeDisconnected());
    await settle();

    // The backend does not end a session because a socket went away.
    expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
    expect(remoteSessionRepository.currentCount, 1);
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

    expect(remoteSessionRepository.currentCount, 1);
  });

  test('the technician closing ends the assistance with no intervention',
      () async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    supportRepository.currentResult = const Ok<SupportRequest?>(acceptedRequest);
    await reachConnected();
    expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());

    // The backend closed the session and completed its request in the same
    // transaction.
    remoteSessionRepository.currentResult = noRemoteSession;
    supportRepository.currentResult = const Ok<SupportRequest?>(null);

    await client.emit(
      const RealtimeRemoteSessionClosed(testRemoteSessionId),
    );
    await settle();

    expect(remoteSessionBloc.state, const RemoteSessionIdle());
    // And the request the screen would otherwise fall back to is re-read, so
    // the tablet does not end up offering to cancel a COMPLETED request.
    expect(supportBloc.state, const SupportIdle());
  });

  test('a session that ends from the tablet also refreshes the request',
      () async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    supportRepository.currentResult = const Ok<SupportRequest?>(acceptedRequest);
    await reachConnected();
    final supportReads = supportRepository.currentCount;

    remoteSessionRepository.currentQueue.add(noRemoteSession);
    supportRepository.currentResult = const Ok<SupportRequest?>(null);
    remoteSessionBloc.add(const RemoteSessionCloseRequested());
    await settle();

    expect(remoteSessionRepository.closedIds, [testRemoteSessionId]);
    expect(remoteSessionBloc.state, const RemoteSessionIdle());
    expect(supportRepository.currentCount, supportReads + 1);
    expect(supportBloc.state, const SupportIdle());
  });

  test('a session that was never live does not re-read the request', () async {
    supportRepository.currentResult = const Ok<SupportRequest?>(waitingRequest);
    await reachConnected();
    final supportReads = supportRepository.currentCount;

    // A closure announced for a session this device never had: the read it
    // triggers answers "none", which is what the tablet already believed.
    // Nothing ended, so nothing about the request is stale.
    await client.emit(const RealtimeRemoteSessionClosed(testRemoteSessionId));
    await settle();

    expect(remoteSessionRepository.currentCount, 2);
    expect(supportRepository.currentCount, supportReads);
    expect(supportBloc.state, isA<SupportWaiting>());
  });

  test('a revoked credential clears the remote session', () async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    await reachConnected();
    expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());

    sessionBloc.add(const DeviceSessionCredentialRejected());
    await settle();

    expect(sessionBloc.state, const DeviceSessionReEnrollmentRequired());
    // A remote assistance session must never outlive the credential that
    // authorised it.
    expect(remoteSessionBloc.state, const RemoteSessionInitial());
    expect(supportBloc.state, const SupportInitial());
  });

  test('a read that could not reach the backend is retried on reconnection',
      () async {
    remoteSessionRepository.currentResult = remoteSessionUnreachable;
    supportRepository.currentResult = const Ok<SupportRequest?>(acceptedRequest);
    await reachConnected();
    // Unknown, not "none": the screen says so rather than offering to request
    // assistance that may already be under way.
    expect(remoteSessionBloc.state, isA<RemoteSessionUnavailable>());

    remoteSessionRepository.currentResult = connectingRemoteSession;
    await client.emit(const RealtimeDisconnected());
    await client.emit(const RealtimeConnected());
    await settle();

    expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
  });

  test('a REST call that discovers a revoked credential tears the whole '
      'assistance down', () async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    supportRepository.currentResult = const Ok<SupportRequest?>(acceptedRequest);
    await reachConnected();
    expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
    expect(supportBloc.state, isA<SupportAccepted>());

    // What `AuthenticatedDeviceRequest` reports when the renewal login itself
    // answers 401: the permanent credential is gone, whichever call found out.
    credentialRevocation.report();
    await settle();

    expect(sessionBloc.state, const DeviceSessionReEnrollmentRequired());
    expect(storage.clearCount, 1);
    // Nothing local survives an identity this installation no longer has.
    expect(remoteSessionBloc.state, const RemoteSessionInitial());
    expect(supportBloc.state, const SupportInitial());
    // And the socket is released rather than left reconnecting with a token
    // minted from a credential the backend has revoked.
    expect(client.disconnectCount, greaterThan(0));
    expect(realtimeBloc.state, isA<DeviceRealtimeDisconnected>());
  });

  test('the coordinator stops listening once disposed', () async {
    await reachConnected();
    await coordinator.dispose();

    await client.emit(
      const RealtimeRemoteSessionCreated(
        remoteSessionId: testRemoteSessionId,
        supportRequestId: testSupportRequestId,
        technicianId: testTechnicianId,
      ),
    );
    await settle();

    expect(remoteSessionRepository.currentCount, 1);
  });
}
