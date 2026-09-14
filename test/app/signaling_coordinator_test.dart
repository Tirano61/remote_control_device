import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/app/device_realtime_coordinator.dart';
import 'package:remote_control_device/app/remote_session_coordinator.dart';
import 'package:remote_control_device/app/signaling_coordinator.dart';
import 'package:remote_control_device/app/support_coordinator.dart';
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
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_device/features/signaling/domain/entities/join_remote_session_result.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_error_code.dart';
import 'package:remote_control_device/features/signaling/presentation/bloc/signaling/signaling_bloc.dart';
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
import '../fakes/signaling_fakes.dart';
import '../fakes/support_fakes.dart';

/// The blocs are real; only the socket, the secure store and the HTTP
/// repositories are faked. What is under test is when a `remote-session:join`
/// is emitted and when it must not be — the conjunction the contract requires,
/// and everything that can break it.
///
/// The other coordinators run too, because in the application they always do:
/// the session that signaling joins is the one they put on screen.
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
  late SignalingBloc signalingBloc;
  late DeviceCredentialRevocation credentialRevocation;
  late DeviceRealtimeCoordinator realtimeCoordinator;
  late SupportCoordinator supportCoordinator;
  late RemoteSessionCoordinator remoteSessionCoordinator;
  late SignalingCoordinator coordinator;

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
    signalingBloc = SignalingBloc(client: client);

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
    remoteSessionCoordinator = RemoteSessionCoordinator(
      realtimeClient: client,
      realtimeBloc: realtimeBloc,
      sessionBloc: sessionBloc,
      supportBloc: supportBloc,
      remoteSessionBloc: remoteSessionBloc,
    )..start();
    coordinator = SignalingCoordinator(
      realtimeBloc: realtimeBloc,
      remoteSessionBloc: remoteSessionBloc,
      signalingBloc: signalingBloc,
    )..start();
  });

  tearDown(() async {
    await coordinator.dispose();
    await remoteSessionCoordinator.dispose();
    await supportCoordinator.dispose();
    await realtimeCoordinator.dispose();
    await credentialRevocation.dispose();
    await signalingBloc.close();
    await remoteSessionBloc.close();
    await supportBloc.close();
    await realtimeBloc.close();
    await sessionBloc.close();
  });

  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// The device is authenticated and its socket is up.
  Future<void> reachConnected() async {
    sessionBloc.add(const DeviceSessionStarted());
    await settle();
    realtimeBloc.add(const DeviceRealtimeStartRequested());
    await settle();
    await client.emit(const RealtimeConnected());
    await settle();
  }

  test('a live session on a live socket is joined, with nobody pressing '
      'anything', () async {
    // The user already authorised the assistance with PERMITIR; the join is a
    // consequence of that, not a second decision.
    remoteSessionRepository.currentResult = connectingRemoteSession;

    await reachConnected();

    expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
    expect(client.joinedSessionIds, [testRemoteSessionId]);
    expect(signalingBloc.state, const SignalingJoined(testRemoteSessionId));
  });

  test('this is also the restart story', () async {
    // Nothing announces the session — it was created while the application was
    // not running. The REST recovery finds it and the join follows.
    remoteSessionRepository.currentResult = connectingRemoteSession;

    await reachConnected();

    expect(remoteSessionRepository.currentCount, 1);
    expect(client.joinedSessionIds, [testRemoteSessionId]);
  });

  test('an ACTIVE session is joinable too', () async {
    remoteSessionRepository.currentResult = activeRemoteSession;

    await reachConnected();

    expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
    expect(client.joinedSessionIds, [testRemoteSessionId]);
  });

  test('no session means no join', () async {
    await reachConnected();

    expect(remoteSessionBloc.state, const RemoteSessionIdle());
    expect(client.joinedSessionIds, isEmpty);
    expect(signalingBloc.state, const SignalingIdle());
  });

  test('a session with no socket is not joined', () async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    // The session is recovered, then the socket goes away before anything else.
    await reachConnected();
    expect(client.joinedSessionIds, hasLength(1));

    await client.emit(const RealtimeDisconnected());
    await settle();

    expect(signalingBloc.state, const SignalingIdle());
    // The session itself is untouched: a dropped socket ends no assistance.
    expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
    expect(client.joinedSessionIds, hasLength(1));
  });

  test('a reconnection joins again — the old room did not survive', () async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    await reachConnected();

    await client.emit(const RealtimeDisconnected());
    await settle();
    expect(signalingBloc.state, const SignalingIdle());

    await client.emit(const RealtimeConnected());
    await settle();

    expect(client.joinedSessionIds, [
      testRemoteSessionId,
      testRemoteSessionId,
    ]);
    expect(signalingBloc.state, const SignalingJoined(testRemoteSessionId));
  });

  test('remote-session:created leads to exactly one join', () async {
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

    expect(client.joinedSessionIds, [testRemoteSessionId]);
  });

  test('everything that re-reads the same session still joins only once',
      () async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    supportRepository.currentResult = const Ok<SupportRequest?>(assignedRequest);
    await reachConnected();

    // Three more things that each cause a GET /device/remote-sessions/current.
    await client.emit(
      const RealtimeRemoteSessionCreated(
        remoteSessionId: testRemoteSessionId,
        supportRequestId: testSupportRequestId,
        technicianId: testTechnicianId,
      ),
    );
    supportBloc.add(const SupportAcceptRequested());
    await settle();
    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle();

    expect(remoteSessionRepository.currentCount, greaterThan(1));
    expect(client.joinedSessionIds, [testRemoteSessionId]);
  });

  test('a new session is joined on its own id, and the old state is gone',
      () async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    await reachConnected();
    expect(signalingBloc.state, const SignalingJoined(testRemoteSessionId));

    // Session A closes and session B is created. Only B can be joined now.
    const sessionB = RemoteSession(
      id: testOtherRemoteSessionId,
      supportRequestId: testSupportRequestId,
      status: RemoteSessionStatus.connecting,
      technician: testRemoteSessionTechnician,
    );
    remoteSessionRepository.currentResult = const Ok<RemoteSession?>(sessionB);
    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle();

    expect(client.joinedSessionIds, [
      testRemoteSessionId,
      testOtherRemoteSessionId,
    ]);
    expect(
      signalingBloc.state,
      const SignalingJoined(testOtherRemoteSessionId),
    );
  });

  test('a session that ends clears signaling without closing anything else',
      () async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    await reachConnected();
    expect(signalingBloc.state, isA<SignalingJoined>());

    remoteSessionRepository.currentResult = noRemoteSession;
    await client.emit(const RealtimeRemoteSessionClosed(testRemoteSessionId));
    await settle();

    expect(remoteSessionBloc.state, const RemoteSessionIdle());
    expect(signalingBloc.state, const SignalingIdle());
    // The socket stays exactly where it was: signaling ending is not the
    // channel ending.
    expect(realtimeBloc.state, isA<DeviceRealtimeConnected>());
  });

  test('a dropped device identity clears signaling too', () async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    await reachConnected();

    sessionBloc.add(const DeviceSessionCredentialRejected());
    await settle();

    expect(remoteSessionBloc.state, const RemoteSessionInitial());
    expect(signalingBloc.state, const SignalingIdle());
  });

  group('UNAUTHORIZED', () {
    setUp(() {
      client.joinResult = const RemoteSessionJoinRefused(
        SignalingErrorCode.unauthorized,
      );
    });

    test('never touches the credential', () async {
      remoteSessionRepository.currentResult = connectingRemoteSession;

      await reachConnected();

      expect(
        signalingBloc.state,
        const SignalingUnavailable(
          testRemoteSessionId,
          error: SignalingErrorCode.unauthorized,
        ),
      );
      // The socket's own handshake was validated; an ownership answer about
      // one session says nothing about the deviceSecret.
      expect(storage.clearCount, 0);
      expect(sessionBloc.state, isA<DeviceSessionReady>());
      expect(realtimeBloc.state, isA<DeviceRealtimeConnected>());
    });

    test('reconciles with the backend instead', () async {
      // The first read is the one that put the session on screen; a second one
      // can only be the refusal being reconciled.
      remoteSessionRepository.currentResult = connectingRemoteSession;

      await reachConnected();
      await settle();

      // GET /device/remote-sessions/current is what settles which session is
      // really there — the refusal itself decides nothing.
      expect(remoteSessionRepository.currentCount, 2);
      expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
    });

    test('a refresh that finds the session gone ends signaling quietly',
        () async {
      remoteSessionRepository.currentQueue.add(connectingRemoteSession);
      remoteSessionRepository.currentResult = noRemoteSession;

      await reachConnected();
      await settle();

      expect(remoteSessionBloc.state, const RemoteSessionIdle());
      expect(signalingBloc.state, const SignalingIdle());
      expect(client.joinedSessionIds, hasLength(1));
    });

    test('a refresh that finds the same session does not start a loop',
        () async {
      remoteSessionRepository.currentResult = connectingRemoteSession;

      await reachConnected();
      for (var i = 0; i < 5; i++) {
        await settle();
      }

      // One join, and a bounded number of reads: the refusal is recorded and
      // the client waits for something real to change rather than spinning.
      expect(client.joinedSessionIds, hasLength(1));
      expect(remoteSessionRepository.currentCount, lessThan(5));
      expect(signalingBloc.state, isA<SignalingUnavailable>());
    });

    test('a new socket is what makes it try again', () async {
      remoteSessionRepository.currentResult = connectingRemoteSession;
      await reachConnected();
      expect(client.joinedSessionIds, hasLength(1));

      client.joinResult = const RemoteSessionJoined('');
      await client.emit(const RealtimeDisconnected());
      await settle();
      await client.emit(const RealtimeConnected());
      await settle();

      expect(client.joinedSessionIds, hasLength(2));
      expect(signalingBloc.state, const SignalingJoined(testRemoteSessionId));
    });
  });

  group('UNAVAILABLE', () {
    test('refreshes the session and then holds still', () async {
      client.joinResult = const RemoteSessionJoinRefused(
        SignalingErrorCode.unavailable,
      );
      remoteSessionRepository.currentResult = connectingRemoteSession;

      await reachConnected();
      for (var i = 0; i < 5; i++) {
        await settle();
      }

      expect(remoteSessionRepository.currentCount, greaterThan(1));
      expect(remoteSessionRepository.currentCount, lessThan(5));
      expect(client.joinedSessionIds, hasLength(1));
      expect(
        signalingBloc.state,
        const SignalingUnavailable(
          testRemoteSessionId,
          error: SignalingErrorCode.unavailable,
        ),
      );
    });
  });

  group('INVALID_PAYLOAD', () {
    test('is treated as the contract error it is: no retry, no refresh',
        () async {
      client.joinResult = const RemoteSessionJoinRefused(
        SignalingErrorCode.invalidPayload,
      );
      remoteSessionRepository.currentResult = connectingRemoteSession;

      await reachConnected();
      final reads = remoteSessionRepository.currentCount;
      for (var i = 0; i < 5; i++) {
        await settle();
      }

      expect(client.joinedSessionIds, hasLength(1));
      // Re-reading the session would only add a call to a bug on this side.
      expect(remoteSessionRepository.currentCount, reads);
      expect(
        signalingBloc.state,
        const SignalingUnavailable(
          testRemoteSessionId,
          error: SignalingErrorCode.invalidPayload,
        ),
      );
    });
  });

  test('a join whose ACK never came is retried by the next connection only',
      () async {
    client.joinResult = const RemoteSessionJoinUnanswered();
    remoteSessionRepository.currentResult = connectingRemoteSession;
    await reachConnected();
    expect(signalingBloc.state, const SignalingUnavailable(testRemoteSessionId));

    client.joinResult = const RemoteSessionJoined('');
    await client.emit(const RealtimeDisconnected());
    await client.emit(const RealtimeConnected());
    await settle();

    expect(client.joinedSessionIds, hasLength(2));
    expect(signalingBloc.state, const SignalingJoined(testRemoteSessionId));
  });

  test('the offer the WebRTC prompt will send reaches the wire unchanged',
      () async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    await reachConnected();

    await signalingBloc.sendOffer(testOffer);

    expect(client.sentOffers.single.remoteSessionId, testRemoteSessionId);
    expect(client.sentOffers.single.sdp, testSdp);
  });

  test('the coordinator stops deciding once disposed', () async {
    await reachConnected();
    await coordinator.dispose();

    remoteSessionRepository.currentResult = connectingRemoteSession;
    remoteSessionBloc.add(const RemoteSessionSyncRequested());
    await settle();

    expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
    expect(client.joinedSessionIds, isEmpty);
  });
}
