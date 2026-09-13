import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/domain/entities/device_realtime_confirmation.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';

import '../../../fakes/device_fakes.dart';
import '../../../fakes/realtime_fakes.dart';

void main() {
  late FakeDeviceRealtimeClient client;
  late FakeDeviceCredentialsStorage storage;
  late FakeDeviceAuthRepository authRepository;
  late DeviceTokenStore tokenStore;

  const confirmation = DeviceRealtimeConfirmation(
    deviceId: testDeviceId,
    publicId: testPublicId,
  );

  // Only the socket and the two ports at the edges are faked; the renewal use
  // case and its collaborators are the real ones.
  DeviceRealtimeBloc buildBloc() => DeviceRealtimeBloc(
    client: client,
    tokenStore: tokenStore,
    renewDeviceToken: RenewDeviceToken(
      loadDeviceCredentials: LoadDeviceCredentials(storage),
      authenticateDevice: AuthenticateDevice(authRepository),
    ),
    reauthRetryDelay: const Duration(milliseconds: 20),
  );

  setUp(() {
    client = FakeDeviceRealtimeClient();
    storage = FakeDeviceCredentialsStorage(testCredentials);
    tokenStore = InMemoryDeviceTokenStore()..save(testDeviceJwt);
    authRepository = FakeDeviceAuthRepository(
      loginResult: const Ok(testRenewedSession),
      tokenStore: tokenStore,
    );
  });

  group('starting the channel', () {
    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a ready session connects with the current Device JWT',
      build: buildBloc,
      act: (bloc) => bloc.add(const DeviceRealtimeStartRequested()),
      expect: () => const [DeviceRealtimeConnecting()],
      verify: (_) => expect(client.connectedWithTokens, [testDeviceJwt]),
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'without a Device JWT nothing is opened',
      build: buildBloc,
      seed: () => const DeviceRealtimeConnecting(),
      act: (bloc) {
        tokenStore.clear();
        bloc.add(const DeviceRealtimeStartRequested());
      },
      expect: () => const [DeviceRealtimeDisconnected()],
      verify: (_) => expect(client.connectedWithTokens, isEmpty),
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'repeating the request does not churn a live connection',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeConnected());
        bloc.add(const DeviceRealtimeStartRequested());
      },
      expect: () => const [DeviceRealtimeConnecting(), DeviceRealtimeConnected()],
      verify: (_) {
        expect(client.connectedWithTokens, [testDeviceJwt]);
        expect(client.disconnectCount, 0);
      },
    );
  });

  group('connected', () {
    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a successful handshake reports the channel as connected',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeConnected());
      },
      expect: () => const [DeviceRealtimeConnecting(), DeviceRealtimeConnected()],
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'device:connected is recorded as a confirmation of the channel',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeConnected());
        await client.emit(const RealtimeIdentityConfirmed(confirmation));
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnected(),
        DeviceRealtimeConnected(confirmation: confirmation),
      ],
      verify: (bloc) {
        // It confirms; it does not become the device identity. That still comes
        // from check-status, and lives in DeviceSessionBloc.
        final state = bloc.state as DeviceRealtimeConnected;
        expect(
          state.confirmation!.matches(
            deviceId: testIdentity.id,
            publicId: testIdentity.publicId,
          ),
          isTrue,
        );
      },
    );
  });

  test('device:connected arriving without a live connection is ignored', () async {
    final bloc = buildBloc();
    addTearDown(bloc.close);

    bloc.add(const DeviceRealtimeStartRequested());
    await FakeDeviceRealtimeClient.pump();
    await client.emit(const RealtimeIdentityConfirmed(confirmation));

    expect(bloc.state, const DeviceRealtimeConnecting());
  });

  group('network loss', () {
    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'losing an established connection is a reconnection, not a logout',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeConnected());
        await client.emit(const RealtimeDisconnected());
        await client.emit(const RealtimeReconnectAttempt());
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnected(),
        DeviceRealtimeReconnecting(),
      ],
      verify: (_) {
        // Nothing about the installation identity is touched by a bad network.
        expect(storage.credentials, testCredentials);
        expect(storage.clearCount, 0);
        expect(tokenStore.token, testDeviceJwt);
        expect(authRepository.loginCount, 0);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'the network coming back reconnects the same socket',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeConnected());
        await client.emit(const RealtimeDisconnected());
        await client.emit(const RealtimeConnected());
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnected(),
        DeviceRealtimeReconnecting(),
        DeviceRealtimeConnected(),
      ],
      verify: (_) {
        // Socket.IO reconnects on its own: no second handshake was built here.
        expect(client.connectedWithTokens, [testDeviceJwt]);
        expect(authRepository.loginCount, 0);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'an unreachable backend at startup reads as no connection',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeConnectFailed());
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnectionError(),
      ],
      verify: (_) {
        expect(storage.clearCount, 0);
        expect(authRepository.loginCount, 0);
      },
    );
  });

  group('handshake refused with a renewable credential', () {
    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'renews the Device JWT and reconnects with the new one',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeConnected());
        await client.emit(const RealtimeHandshakeRejected());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeConnected());
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnected(),
        DeviceRealtimeReconnecting(),
        DeviceRealtimeConnected(),
      ],
      verify: (_) {
        expect(authRepository.loginCount, 1);
        expect(authRepository.lastLoginCredentials, testCredentials);
        // The second handshake must carry the renewed token, not the refused
        // one — the whole point of rebuilding the socket.
        expect(client.connectedWithTokens, [
          testDeviceJwt,
          testRenewedDeviceJwt,
        ]);
        // And the store now holds it, for the HTTP side too.
        expect(tokenStore.token, testRenewedDeviceJwt);
        // Reconnection with the refused token was stopped first.
        expect(client.disconnectCount, 1);
        expect(storage.clearCount, 0);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a refusal on the very first attempt is recovered the same way',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeHandshakeRejected());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeConnected());
      },
      expect: () => const [DeviceRealtimeConnecting(), DeviceRealtimeConnected()],
      verify: (_) => expect(client.connectedWithTokens, [
        testDeviceJwt,
        testRenewedDeviceJwt,
      ]),
    );
  });

  group('permanent credential revoked', () {
    setUp(() => authRepository.loginResult = loginUnauthorized);

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a 401 on login releases the socket and reports the credential is gone',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeConnected());
        await client.emit(const RealtimeHandshakeRejected());
        await FakeDeviceRealtimeClient.pump();
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnected(),
        DeviceRealtimeReconnecting(),
        DeviceRealtimeDisconnected(
          cause: DeviceRealtimeStopCause.credentialRejected,
        ),
      ],
      verify: (_) {
        expect(authRepository.loginCount, 1);
        // The socket is released and nothing tries again.
        expect(client.connectedWithTokens, [testDeviceJwt]);
        expect(client.disconnectCount, greaterThanOrEqualTo(1));
        // Wiping the credential belongs to the session bloc, which the
        // coordinator hands this over to; the realtime layer only reports it.
        expect(storage.clearCount, 0);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a credential that vanished from secure storage is treated as revoked',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        storage.credentials = null;
        await client.emit(const RealtimeHandshakeRejected());
        await FakeDeviceRealtimeClient.pump();
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeDisconnected(
          cause: DeviceRealtimeStopCause.credentialRejected,
        ),
      ],
      verify: (_) => expect(authRepository.loginCount, 0),
    );
  });

  group('network failure while renewing', () {
    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'keeps the permanent credential and stays retryable',
      build: buildBloc,
      act: (bloc) async {
        authRepository.loginResult = loginUnreachable;
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeHandshakeRejected());
        await FakeDeviceRealtimeClient.pump();
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnectionError(),
      ],
      verify: (_) {
        // Nothing was learnt about the credential, so nothing is destroyed.
        expect(storage.credentials, testCredentials);
        expect(storage.clearCount, 0);
        expect(authRepository.loginCount, 1);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'retries later and connects once the backend answers again',
      build: buildBloc,
      act: (bloc) async {
        authRepository.loginResult = loginUnreachable;
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeHandshakeRejected());
        await FakeDeviceRealtimeClient.pump();
        authRepository.loginResult = const Ok(testRenewedSession);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await client.emit(const RealtimeConnected());
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnectionError(),
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnected(),
      ],
      verify: (_) {
        // Two logins: the one that could not reach the backend, and the retry.
        expect(authRepository.loginCount, 2);
        expect(client.connectedWithTokens, [
          testDeviceJwt,
          testRenewedDeviceJwt,
        ]);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a server error while renewing is not a revoked credential either',
      build: buildBloc,
      act: (bloc) async {
        authRepository.loginResult = const Err(ServerFailure());
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeHandshakeRejected());
        await FakeDeviceRealtimeClient.pump();
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnectionError(),
      ],
      verify: (_) => expect(storage.clearCount, 0),
    );
  });

  group('no authentication loop', () {
    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a token that was just issued and refused again ends the attempts',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeHandshakeRejected());
        await FakeDeviceRealtimeClient.pump();
        // The renewed token is refused as well.
        await client.emit(const RealtimeHandshakeRejected());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeHandshakeRejected());
        await FakeDeviceRealtimeClient.pump();
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnectionError(retrying: false),
      ],
      verify: (_) {
        // One login, not one per rejection.
        expect(authRepository.loginCount, 1);
        expect(client.connectedWithTokens, [
          testDeviceJwt,
          testRenewedDeviceJwt,
        ]);
        expect(storage.clearCount, 0);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'rejections arriving together produce a single login',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        client
          ..emit(const RealtimeHandshakeRejected())
          ..emit(const RealtimeHandshakeRejected())
          ..emit(const RealtimeHandshakeRejected());
        await FakeDeviceRealtimeClient.pump();
        await FakeDeviceRealtimeClient.pump();
      },
      verify: (_) {
        expect(authRepository.loginCount, 1);
        expect(client.connectedWithTokens.length, 2);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a working connection restores the right to recover once more',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeHandshakeRejected());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeConnected());
        // A day later the renewed token expires in its turn.
        authRepository.loginResult = const Ok(testSession);
        await client.emit(const RealtimeHandshakeRejected());
        await FakeDeviceRealtimeClient.pump();
      },
      verify: (_) {
        expect(authRepository.loginCount, 2);
        expect(client.connectedWithTokens, [
          testDeviceJwt,
          testRenewedDeviceJwt,
          testDeviceJwt,
        ]);
      },
    );
  });

  group('session invalidation', () {
    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'stopping releases the socket and ignores anything it says afterwards',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeConnected());
        bloc.add(const DeviceRealtimeStopRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeDisconnected());
        await client.emit(const RealtimeHandshakeRejected());
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnected(),
        DeviceRealtimeDisconnected(),
      ],
      verify: (_) {
        expect(client.disconnectCount, greaterThanOrEqualTo(1));
        expect(authRepository.loginCount, 0);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'stopping an already released channel changes nothing',
      build: buildBloc,
      act: (bloc) => bloc.add(const DeviceRealtimeStopRequested()),
      expect: () => const <DeviceRealtimeState>[],
    );

    test('closing the bloc disposes the socket', () async {
      final bloc = buildBloc();
      bloc.add(const DeviceRealtimeStartRequested());
      await FakeDeviceRealtimeClient.pump();

      await bloc.close();

      expect(client.disposeCount, 1);
    });
  });
}
