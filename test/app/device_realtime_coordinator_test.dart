import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/app/device_realtime_coordinator.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/core/session/device_credential_revocation.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/check_device_status.dart';
import 'package:remote_control_device/features/device/domain/usecases/suspend_device_authorization.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';

import '../fakes/device_fakes.dart';
import '../fakes/realtime_fakes.dart';

/// The two blocs are real here; only the socket, the secure store and the HTTP
/// repository are faked. What is under test is the wiring between them.
void main() {
  late FakeDeviceRealtimeClient client;
  late FakeDeviceCredentialsStorage storage;
  late FakeDeviceAuthRepository authRepository;
  late DeviceTokenStore tokenStore;
  late DeviceSessionBloc sessionBloc;
  late DeviceRealtimeBloc realtimeBloc;
  late DeviceCredentialRevocation credentialRevocation;
  late DeviceRealtimeCoordinator coordinator;

  setUp(() {
    client = FakeDeviceRealtimeClient();
    storage = FakeDeviceCredentialsStorage(testCredentials);
    tokenStore = InMemoryDeviceTokenStore();
    authRepository = FakeDeviceAuthRepository(tokenStore: tokenStore);
    credentialRevocation = DeviceCredentialRevocation();

    final loadDeviceCredentials = LoadDeviceCredentials(storage);
    final authenticateDevice = AuthenticateDevice(authRepository);

    sessionBloc = DeviceSessionBloc(
      loadDeviceCredentials: loadDeviceCredentials,
      authenticateDevice: authenticateDevice,
      checkDeviceStatus: CheckDeviceStatus(authRepository),
      suspendDeviceAuthorization: SuspendDeviceAuthorization(authRepository),
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
    coordinator = DeviceRealtimeCoordinator(
      sessionBloc: sessionBloc,
      realtimeBloc: realtimeBloc,
      credentialRevocation: credentialRevocation,
    )..start();
  });

  tearDown(() async {
    await coordinator.dispose();
    await credentialRevocation.dispose();
    await realtimeBloc.close();
    await sessionBloc.close();
  });

  Future<void> reachReady() async {
    sessionBloc.add(const DeviceSessionStarted());
    await FakeDeviceRealtimeClient.pump();
    await FakeDeviceRealtimeClient.pump();
  }

  test('a device that becomes ready opens the realtime channel', () async {
    await reachReady();

    expect(sessionBloc.state, const DeviceSessionReady(testIdentity));
    // Exactly the JWT that check-status just validated.
    expect(client.connectedWithTokens, [testDeviceJwt]);
    expect(realtimeBloc.state, const DeviceRealtimeConnecting());
  });

  test('nothing is opened before the device is authenticated', () async {
    storage.credentials = null;
    await reachReady();

    expect(sessionBloc.state, const DeviceSessionNotEnrolled());
    expect(client.connectedWithTokens, isEmpty);
    expect(realtimeBloc.state, const DeviceRealtimeDisconnected());
  });

  test('an unreachable backend leaves the channel closed, not the device '
      'unenrolled', () async {
    authRepository.loginResult = loginUnreachable;
    await reachReady();

    expect(sessionBloc.state, isA<DeviceSessionAuthenticationUnavailable>());
    expect(client.connectedWithTokens, isEmpty);
    expect(storage.credentials, testCredentials);
  });

  test('losing the session releases the socket', () async {
    await reachReady();
    await client.emit(const RealtimeConnected());
    expect(realtimeBloc.state, const DeviceRealtimeConnected());

    // The user asked to retry, so the session leaves READY and re-authenticates.
    authRepository.loginResult = loginUnreachable;
    sessionBloc.add(const DeviceSessionRetryRequested());
    await FakeDeviceRealtimeClient.pump();
    await FakeDeviceRealtimeClient.pump();

    expect(realtimeBloc.state, const DeviceRealtimeDisconnected());
    expect(client.disconnectCount, greaterThanOrEqualTo(1));
  });

  test('a refused deviceSecret withdraws authorisation and keeps the '
      'credential', () async {
    await reachReady();
    await client.emit(const RealtimeConnected());

    // From here on the backend refuses both the socket and the credential.
    authRepository.loginResult = loginRejected;
    await client.emit(const RealtimeHandshakeRejected());
    await FakeDeviceRealtimeClient.pump();
    await FakeDeviceRealtimeClient.pump();

    expect(sessionBloc.state, const DeviceSessionCredentialRefused());
    // Deactivated or replaced cannot be told apart, so nothing is wiped.
    expect(storage.credentials, testCredentials);
    expect(storage.clearCount, 0);
    expect(tokenStore.hasToken, isFalse);
    // One handshake attempt, one login, and then nothing further.
    expect(client.connectedWithTokens, [testDeviceJwt]);
    expect(
      realtimeBloc.state,
      const DeviceRealtimeDisconnected(
        cause: DeviceRealtimeStopCause.credentialRejected,
      ),
    );
  });

  test('P35 F: a deactivation the server announces by closing the socket ends '
      'in CredentialRefused, and an explicit retry after reactivation '
      'recovers with the same credential', () async {
    await reachReady();
    await client.emit(const RealtimeConnected());

    // PATCH isActive=false: the backend closes the socket (io server
    // disconnect) and from now on refuses the login.
    authRepository.loginResult = loginRejected;
    await client.emit(const RealtimeServerDisconnected());
    await FakeDeviceRealtimeClient.pump();
    await FakeDeviceRealtimeClient.pump();

    expect(sessionBloc.state, const DeviceSessionCredentialRefused());
    expect(tokenStore.hasToken, isFalse);
    expect(storage.clearCount, 0);
    expect(authRepository.loginCount, 2, reason: 'startup + one renewal');
    expect(client.connectedWithTokens, [testDeviceJwt]);

    // Nothing is retried on its own...
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(authRepository.loginCount, 2);
    expect(authRepository.checkStatusCount, 1);

    // ...until the admin reactivates the device and the user retries.
    authRepository.loginResult = const Ok(testSession);
    sessionBloc.add(const DeviceSessionRetryRequested());
    await FakeDeviceRealtimeClient.pump();
    await FakeDeviceRealtimeClient.pump();
    await client.emit(const RealtimeConnected());

    expect(sessionBloc.state, const DeviceSessionReady(testIdentity));
    expect(realtimeBloc.state, const DeviceRealtimeConnected());
    expect(storage.credentials, testCredentials);
    expect(client.connectedWithTokens, [testDeviceJwt, testDeviceJwt]);
  });

  test('P35 G2: a server disconnect of an active device stays READY and '
      'reconnects with a renewed JWT', () async {
    await reachReady();
    await client.emit(const RealtimeConnected());

    authRepository.loginResult = const Ok(testRenewedSession);
    await client.emit(const RealtimeServerDisconnected());
    await FakeDeviceRealtimeClient.pump();
    await client.emit(const RealtimeConnected());

    expect(sessionBloc.state, const DeviceSessionReady(testIdentity));
    expect(client.connectedWithTokens, [testDeviceJwt, testRenewedDeviceJwt]);
    expect(realtimeBloc.state, const DeviceRealtimeConnected());
  });

  test('an expired Device JWT never sends the device back to enrollment',
      () async {
    await reachReady();
    await client.emit(const RealtimeConnected());

    authRepository.loginResult = const Ok(testRenewedSession);
    await client.emit(const RealtimeHandshakeRejected());
    await FakeDeviceRealtimeClient.pump();
    await client.emit(const RealtimeConnected());

    expect(sessionBloc.state, const DeviceSessionReady(testIdentity));
    expect(storage.credentials, testCredentials);
    expect(client.connectedWithTokens, [testDeviceJwt, testRenewedDeviceJwt]);
    expect(realtimeBloc.state, const DeviceRealtimeConnected());
  });

  test('a REST call that discovers the revoked credential reaches the same '
      'place as the socket does', () async {
    await reachReady();
    await client.emit(const RealtimeConnected());

    // What an authenticated support call does after POST /device-auth/login
    // answered 401: it reports the fact and nothing else.
    credentialRevocation.report();
    await FakeDeviceRealtimeClient.pump();
    await FakeDeviceRealtimeClient.pump();

    expect(sessionBloc.state, const DeviceSessionCredentialRefused());
    expect(storage.credentials, testCredentials);
    expect(tokenStore.hasToken, isFalse);
    expect(realtimeBloc.state, const DeviceRealtimeDisconnected());
    // No second login was attempted: the REST side had already established it.
    expect(authRepository.loginCount, 1);
  });

  test('the coordinator stops driving the blocs once disposed', () async {
    await reachReady();
    await coordinator.dispose();

    sessionBloc.add(const DeviceSessionRetryRequested());
    await FakeDeviceRealtimeClient.pump();
    await FakeDeviceRealtimeClient.pump();

    // Still whatever the last coordinated decision left behind.
    expect(client.connectedWithTokens, [testDeviceJwt]);
  });
}
