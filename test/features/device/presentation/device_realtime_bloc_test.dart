import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/domain/entities/device_realtime_confirmation.dart';
import 'package:remote_control_device/features/device/domain/entities/device_session.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';

import '../../../fakes/device_fakes.dart';
import '../../../fakes/manual_timers.dart';
import '../../../fakes/realtime_fakes.dart';

void main() {
  late FakeDeviceRealtimeClient client;
  late FakeDeviceCredentialsStorage storage;
  late FakeDeviceAuthRepository authRepository;
  late DeviceTokenStore tokenStore;
  late ManualTimers timers;

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
    timerFactory: timers.factory,
    clock: () => DateTime.utc(2026, 11, 19).add(timers.now),
  );

  setUp(() {
    timers = ManualTimers();
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
    setUp(() => authRepository.loginResult = loginRejected);

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a DEVICE_CREDENTIAL_REJECTED login releases the socket and reports it',
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
        // The realtime layer only reports it; nothing anywhere wipes it.
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

  group('13. a refused handshake whose renewal confirms nothing', () {
    for (final (name, renewal) in [
      ('a code-less 401 (private tunnel)', loginUnauthorized),
      ('a server error', const Err<DeviceSession>(ServerFailure())),
    ]) {
      blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
        '$name is not a revocation: credential kept, retried later',
        build: buildBloc,
        act: (bloc) async {
          authRepository.loginResult = renewal;
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
          DeviceRealtimeConnectionError(),
        ],
        verify: (bloc) {
          expect(bloc.state, isNot(isA<DeviceRealtimeDisconnected>()));
          expect(storage.credentials, testCredentials);
          expect(storage.clearCount, 0);
          expect(authRepository.loginCount, 1);
        },
      );
    }
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
        timers.elapse(const Duration(milliseconds: 20));
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeConnected());
        // Once connected, nothing is left scheduled.
        expect(timers.pending, isEmpty);
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
        expect(timers.pending, isEmpty);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a connection that stayed up restores the immediate recovery',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeHandshakeRejected());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeConnected());
        // It stays up long enough to count as stable...
        timers.elapse(DeviceRealtimeBloc.defaultStableConnectionPeriod);
        // ...and a day later the renewed token expires in its turn.
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

  group('P35 — a refusal after a fresh login is never terminal', () {
    Future<void> start(DeviceRealtimeBloc bloc) async {
      bloc.add(const DeviceRealtimeStartRequested());
      await FakeDeviceRealtimeClient.pump();
    }

    Future<void> reject() async {
      await client.emit(const RealtimeHandshakeRejected());
      await FakeDeviceRealtimeClient.pump();
    }

    Duration nextDelay() => timers.pending.single.dueAt - timers.now;

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'C: a freshly minted JWT refused again is retried after 15 s, '
      'and connects once the backend is healthy',
      build: buildBloc,
      act: (bloc) async {
        await start(bloc);
        await reject(); // login 1 at once
        await reject(); // the fresh token is refused too
        expect(authRepository.loginCount, 1, reason: 'nothing before 15 s');
        expect(nextDelay(), const Duration(seconds: 15));
        timers.elapse(const Duration(seconds: 14));
        await FakeDeviceRealtimeClient.pump();
        expect(authRepository.loginCount, 1);
        authRepository.loginResult = const Ok(testSession);
        timers.elapse(const Duration(seconds: 1));
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeConnected());
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnectionError(),
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnected(),
      ],
      verify: (_) {
        expect(authRepository.loginCount, 2);
        // Three handshakes, each on a socket of its own.
        expect(client.connectedWithTokens, [
          testDeviceJwt,
          testRenewedDeviceJwt,
          testDeviceJwt,
        ]);
        expect(storage.clearCount, 0);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'the backoff is 15 s, 30 s, 60 s, then 60 s for as long as it takes',
      build: buildBloc,
      act: (bloc) async {
        await start(bloc);
        await reject();
        final delays = <Duration>[];
        for (var i = 0; i < 5; i++) {
          await reject();
          delays.add(nextDelay());
          timers.elapse(delays.last);
          await FakeDeviceRealtimeClient.pump();
        }
        expect(delays, const [
          Duration(seconds: 15),
          Duration(seconds: 30),
          Duration(seconds: 60),
          Duration(seconds: 60),
          Duration(seconds: 60),
        ]);
      },
      verify: (_) {
        // One login per step, never two at once, never more than one timer.
        expect(authRepository.loginCount, 6);
        expect(client.connectedWithTokens.length, 7);
        expect(timers.pending, isEmpty);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a connection that drops before it is stable does not reset the backoff',
      build: buildBloc,
      act: (bloc) async {
        await start(bloc);
        await reject(); // login 1 at once
        await client.emit(const RealtimeConnected());
        timers.elapse(const Duration(seconds: 5)); // not yet stable
        await reject();
        expect(authRepository.loginCount, 1);
        expect(nextDelay(), const Duration(seconds: 15));
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a confirmed refusal during the backoff stops everything',
      build: buildBloc,
      act: (bloc) async {
        await start(bloc);
        await reject();
        await reject();
        authRepository.loginResult = loginRejected;
        timers.elapse(const Duration(seconds: 15));
        await FakeDeviceRealtimeClient.pump();
        // Whatever arrives afterwards changes nothing.
        await reject();
        timers.elapse(const Duration(minutes: 10));
        await FakeDeviceRealtimeClient.pump();
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnectionError(),
        DeviceRealtimeConnecting(),
        DeviceRealtimeDisconnected(
          cause: DeviceRealtimeStopCause.credentialRejected,
        ),
      ],
      verify: (_) {
        expect(authRepository.loginCount, 2);
        expect(timers.pending, isEmpty);
        expect(storage.clearCount, 0);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a namespace refusal that destroyed the socket is recovered like one',
      build: buildBloc,
      act: (bloc) async {
        await start(bloc);
        await client.emit(const RealtimeConnectFailed(transportRetrying: false));
        await FakeDeviceRealtimeClient.pump();
      },
      verify: (_) {
        expect(authRepository.loginCount, 1);
        expect(client.connectedWithTokens, [testDeviceJwt, testRenewedDeviceJwt]);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a transport failure the package retries costs no login',
      build: buildBloc,
      act: (bloc) async {
        await start(bloc);
        await client.emit(const RealtimeConnectFailed());
        timers.elapse(const Duration(minutes: 5));
        await FakeDeviceRealtimeClient.pump();
      },
      verify: (_) {
        expect(authRepository.loginCount, 0);
        expect(client.connectedWithTokens, [testDeviceJwt]);
        expect(timers.pending, isEmpty);
      },
    );
  });

  group('P35 — io server disconnect', () {
    Future<void> connected(DeviceRealtimeBloc bloc) async {
      bloc.add(const DeviceRealtimeStartRequested());
      await FakeDeviceRealtimeClient.pump();
      await client.emit(const RealtimeConnected());
    }

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'G2: the server closing an active device re-authenticates and reconnects',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        await client.emit(const RealtimeServerDisconnected());
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
        // The destroyed socket is released, a new one built with the new JWT.
        expect(client.disconnectCount, 1);
        expect(client.connectedWithTokens, [testDeviceJwt, testRenewedDeviceJwt]);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'F1: a deactivated device finds out through the login and stops',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        authRepository.loginResult = loginRejected;
        await client.emit(const RealtimeServerDisconnected());
        await FakeDeviceRealtimeClient.pump();
        timers.elapse(const Duration(minutes: 10));
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
        expect(authRepository.loginCount, 1, reason: 'no automatic loop');
        expect(client.connectedWithTokens, [testDeviceJwt]);
        expect(timers.pending, isEmpty);
        expect(storage.clearCount, 0);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a backend that keeps accepting and dropping the socket is bounded by '
      'the backoff',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        for (var i = 0; i < 4; i++) {
          await client.emit(const RealtimeServerDisconnected());
          await FakeDeviceRealtimeClient.pump();
          final pending = timers.pending;
          if (pending.isNotEmpty) {
            timers.elapse(pending.single.dueAt - timers.now);
            await FakeDeviceRealtimeClient.pump();
          }
          await client.emit(const RealtimeConnected());
        }
      },
      verify: (_) {
        // Four drops, four logins — but spread over 0 + 15 + 30 + 60 s.
        expect(authRepository.loginCount, 4);
        expect(timers.now, const Duration(seconds: 105));
      },
    );
  });

  group('P35 — generations', () {
    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a stop during the login: its answer installs nothing',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        authRepository.loginGate = Completer<void>();
        await client.emit(const RealtimeHandshakeRejected());
        bloc.add(const DeviceRealtimeStopRequested());
        await FakeDeviceRealtimeClient.pump();
        authRepository.loginGate!.complete();
        await FakeDeviceRealtimeClient.pump();
        await FakeDeviceRealtimeClient.pump();
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeDisconnected(),
      ],
      verify: (_) {
        expect(client.connectedWithTokens, [testDeviceJwt]);
        expect(timers.pending, isEmpty);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a late login does not replace the socket of a newer start',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        authRepository.loginGate = Completer<void>();
        await client.emit(const RealtimeHandshakeRejected());
        bloc.add(const DeviceRealtimeStopRequested());
        await FakeDeviceRealtimeClient.pump();
        // The session is READY again with a token of its own.
        tokenStore.save('header.session-payload.signature');
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        authRepository.loginGate!.complete();
        await FakeDeviceRealtimeClient.pump();
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeConnected());
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeDisconnected(),
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnected(),
      ],
      verify: (_) {
        expect(client.connectedWithTokens, [
          testDeviceJwt,
          'header.session-payload.signature',
        ]);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'logins are never concurrent, even across generations',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        authRepository.loginGate = Completer<void>();
        await client.emit(const RealtimeHandshakeRejected()); // login A starts
        bloc.add(const DeviceRealtimeStopRequested());
        await FakeDeviceRealtimeClient.pump();
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeHandshakeRejected()); // B must wait
        await FakeDeviceRealtimeClient.pump();
        expect(authRepository.loginCount, 1);
        authRepository.loginGate!.complete();
        await FakeDeviceRealtimeClient.pump();
        await FakeDeviceRealtimeClient.pump();
      },
      verify: (_) {
        expect(authRepository.loginCount, 2);
        // Only the current generation's renewal opened a socket: the first
        // two are the starts, the third is B's renewal. A's answer opened none.
        expect(client.connectedWithTokens, [
          testDeviceJwt,
          testDeviceJwt,
          testRenewedDeviceJwt,
        ]);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a timer of an earlier generation does nothing',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeHandshakeRejected());
        await FakeDeviceRealtimeClient.pump();
        await client.emit(const RealtimeHandshakeRejected()); // 15 s scheduled
        bloc.add(const DeviceRealtimeStopRequested());
        await FakeDeviceRealtimeClient.pump();
        expect(timers.pending, isEmpty, reason: 'the stop cancels it');
        bloc.add(const DeviceRealtimeStartRequested());
        await FakeDeviceRealtimeClient.pump();
        timers.elapse(const Duration(minutes: 5));
        await FakeDeviceRealtimeClient.pump();
      },
      verify: (_) => expect(authRepository.loginCount, 1),
    );

    test('closing the bloc during a login leaves nothing behind', () async {
      final bloc = buildBloc();
      bloc.add(const DeviceRealtimeStartRequested());
      await FakeDeviceRealtimeClient.pump();
      authRepository.loginGate = Completer<void>();
      await client.emit(const RealtimeHandshakeRejected());
      await bloc.close();
      authRepository.loginGate!.complete();
      await FakeDeviceRealtimeClient.pump();
      await FakeDeviceRealtimeClient.pump();

      expect(client.disposeCount, 1);
      expect(client.connectedWithTokens, [testDeviceJwt]);
      expect(timers.pending, isEmpty);
    });

    test('closing the bloc cancels a scheduled retry', () async {
      final bloc = buildBloc();
      bloc.add(const DeviceRealtimeStartRequested());
      await FakeDeviceRealtimeClient.pump();
      await client.emit(const RealtimeHandshakeRejected());
      await FakeDeviceRealtimeClient.pump();
      await client.emit(const RealtimeHandshakeRejected());
      expect(timers.pending, hasLength(1));

      await bloc.close();

      expect(timers.pending, isEmpty);
      expect(authRepository.loginCount, 1);
    });
  });

  group('P36 — handshake error codes', () {
    Future<void> start(DeviceRealtimeBloc bloc) async {
      bloc.add(const DeviceRealtimeStartRequested());
      await FakeDeviceRealtimeClient.pump();
    }

    Future<void> connected(DeviceRealtimeBloc bloc) async {
      await start(bloc);
      await client.emit(const RealtimeConnected());
    }

    Future<void> unavailable() async {
      await client.emit(const RealtimeHandshakeUnavailable());
      await FakeDeviceRealtimeClient.pump();
    }

    Future<void> unauthorized() async {
      await client.emit(const RealtimeHandshakeRejected());
      await FakeDeviceRealtimeClient.pump();
    }

    Duration nextDelay() => timers.pending.single.dueAt - timers.now;

    Future<void> elapseNext() async {
      timers.elapse(nextDelay());
      await FakeDeviceRealtimeClient.pump();
    }

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      '1. a successful handshake is the only way to Connected',
      build: buildBloc,
      act: (bloc) async {
        await start(bloc);
        await unavailable();
        await elapseNext();
        await client.emit(const RealtimeConnected());
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnectionError(),
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnected(),
      ],
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      '2/11. DEVICE_AUTH_UNAUTHORIZED renews at once and connects with the '
      'new JWT',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        await unauthorized();
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
        expect(client.disconnectCount, 1, reason: 'the dead socket released');
        expect(client.connectedWithTokens, [testDeviceJwt, testRenewedDeviceJwt]);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      '3/20. DEVICE_AUTH_UNAVAILABLE: no login, the JWT is kept, the socket is '
      'released and the channel is not Connected',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        await unavailable();
        expect(bloc.state, const DeviceRealtimeReconnecting());
        expect(nextDelay(), const Duration(seconds: 15),
            reason: 'never retried at once');
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnected(),
        DeviceRealtimeReconnecting(),
      ],
      verify: (_) {
        expect(authRepository.loginCount, 0);
        expect(tokenStore.token, testDeviceJwt);
        expect(storage.credentials, testCredentials);
        expect(storage.clearCount, 0);
        expect(client.disconnectCount, 1);
        expect(client.connectedWithTokens, [testDeviceJwt]);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      '8/9. two UNAVAILABLE in a row: 15 s then 30 s, then the same JWT is '
      'accepted on a new socket — still no login',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        final delays = <Duration>[];
        await unavailable();
        delays.add(nextDelay());
        await elapseNext();
        await unavailable();
        delays.add(nextDelay());
        await elapseNext();
        await client.emit(const RealtimeConnected());
        expect(delays, const [Duration(seconds: 15), Duration(seconds: 30)]);
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnected(),
        DeviceRealtimeReconnecting(),
        DeviceRealtimeConnected(),
      ],
      verify: (_) {
        expect(authRepository.loginCount, 0);
        // Three sockets, one JWT.
        expect(client.connectedWithTokens, [
          testDeviceJwt,
          testDeviceJwt,
          testDeviceJwt,
        ]);
        expect(client.disconnectCount, 2);
        expect(timers.pending, isEmpty);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a long outage is bounded: 15, 30, 60, 60 s, one socket per step',
      build: buildBloc,
      act: (bloc) async {
        await start(bloc);
        final delays = <Duration>[];
        for (var i = 0; i < 5; i++) {
          await unavailable();
          delays.add(nextDelay());
          await elapseNext();
        }
        expect(delays, const [
          Duration(seconds: 15),
          Duration(seconds: 30),
          Duration(seconds: 60),
          Duration(seconds: 60),
          Duration(seconds: 60),
        ]);
      },
      verify: (_) {
        expect(authRepository.loginCount, 0);
        expect(client.connectedWithTokens.length, 6);
        expect(timers.pending, isEmpty);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      '10. the JWT expires during the backoff: the next attempt is refused '
      'and renewed on the backoff, then connects',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        await unavailable();
        await elapseNext(); // same JWT again, 15 s later
        await unauthorized(); // ...now expired
        expect(authRepository.loginCount, 0, reason: 'the backoff holds');
        expect(nextDelay(), const Duration(seconds: 15));
        await elapseNext();
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
        expect(client.connectedWithTokens, [
          testDeviceJwt,
          testDeviceJwt,
          testRenewedDeviceJwt,
        ]);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'never stuck on an expired JWT: after one refusal, the old token is not '
      'presented again',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        await unavailable();
        await elapseNext();
        await unauthorized(); // expired; renewal scheduled
        await elapseNext(); // renewed to testRenewedDeviceJwt
        await unavailable(); // database still down
        await elapseNext();
      },
      verify: (_) {
        expect(authRepository.loginCount, 1);
        expect(client.connectedWithTokens, [
          testDeviceJwt,
          testDeviceJwt,
          testRenewedDeviceJwt,
          testRenewedDeviceJwt,
        ]);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      '12. a confirmed refusal at the login stops everything and keeps the '
      'enrollment',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        await unavailable();
        await elapseNext();
        authRepository.loginResult = loginRejected;
        await unauthorized();
        await elapseNext();
        timers.elapse(const Duration(minutes: 10));
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
        expect(authRepository.loginCount, 1, reason: 'no automatic loop');
        expect(timers.pending, isEmpty);
        expect(storage.credentials, testCredentials);
        expect(storage.clearCount, 0);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      '13. REST renewed the JWT while UNAVAILABLE was backing off: the newer '
      'token is presented, never the older one',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        await unavailable();
        tokenStore.save(testRenewedDeviceJwt); // REST's login, meanwhile
        await elapseNext();
        await client.emit(const RealtimeConnected());
      },
      verify: (_) {
        expect(authRepository.loginCount, 0);
        expect(client.connectedWithTokens, [testDeviceJwt, testRenewedDeviceJwt]);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      '13. REST renewed the JWT while a refusal was backing off: the newer '
      'token is presented without another login',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        await unavailable();
        await elapseNext();
        await unauthorized(); // renewal on the 15 s step
        tokenStore.save('header.rest-payload.signature'); // REST, meanwhile
        await elapseNext();
      },
      verify: (_) {
        expect(authRepository.loginCount, 0);
        expect(client.connectedWithTokens.last, 'header.rest-payload.signature');
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'authorisation withdrawn during the backoff: nothing is presented',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        await unavailable();
        tokenStore.clear(); // the session is withdrawing it
        await elapseNext();
      },
      verify: (_) {
        expect(client.connectedWithTokens, [testDeviceJwt]);
        expect(authRepository.loginCount, 0);
        expect(timers.pending, isEmpty);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'authorisation withdrawn while the renewal was on the wire: its token '
      'opens no socket',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        authRepository.loginGate = Completer<void>();
        await client.emit(const RealtimeHandshakeRejected());
        tokenStore.clear(); // a confirmed refusal elsewhere, say
        authRepository.loginGate!.complete();
        await FakeDeviceRealtimeClient.pump();
        await FakeDeviceRealtimeClient.pump();
      },
      verify: (_) {
        expect(authRepository.loginCount, 1);
        expect(tokenStore.token, isNull, reason: 'not installed (epoch)');
        expect(client.connectedWithTokens, [testDeviceJwt]);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      '14. stop and start during the backoff: the old timer is gone and the '
      'new start connects at once',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        await unavailable();
        bloc.add(const DeviceRealtimeStopRequested());
        await FakeDeviceRealtimeClient.pump();
        expect(timers.pending, isEmpty, reason: 'the stop cancels it');
        await start(bloc);
        timers.elapse(const Duration(minutes: 5));
        await FakeDeviceRealtimeClient.pump();
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnected(),
        DeviceRealtimeReconnecting(),
        DeviceRealtimeDisconnected(),
        DeviceRealtimeConnecting(),
      ],
      verify: (_) {
        expect(client.connectedWithTokens, [testDeviceJwt, testDeviceJwt]);
        expect(authRepository.loginCount, 0);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      '15. an UNAVAILABLE arriving after a stop is ignored',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        bloc.add(const DeviceRealtimeStopRequested());
        await FakeDeviceRealtimeClient.pump();
        await unavailable();
        timers.elapse(const Duration(minutes: 5));
        await FakeDeviceRealtimeClient.pump();
      },
      expect: () => const [
        DeviceRealtimeConnecting(),
        DeviceRealtimeConnected(),
        DeviceRealtimeDisconnected(),
      ],
      verify: (_) {
        expect(timers.pending, isEmpty);
        expect(client.connectedWithTokens, [testDeviceJwt]);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      '16. io server disconnect still renews, as in Prompt 35',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        await client.emit(const RealtimeServerDisconnected());
        await FakeDeviceRealtimeClient.pump();
      },
      verify: (_) {
        expect(authRepository.loginCount, 1);
        expect(client.connectedWithTokens, [testDeviceJwt, testRenewedDeviceJwt]);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'an UNAVAILABLE while a renewal is in flight starts nothing else',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        authRepository.loginGate = Completer<void>();
        await client.emit(const RealtimeHandshakeRejected()); // login starts
        await unavailable(); // a stray one; there is no socket to speak for
        expect(timers.pending, isEmpty);
        authRepository.loginGate!.complete();
        await FakeDeviceRealtimeClient.pump();
        await FakeDeviceRealtimeClient.pump();
      },
      verify: (_) {
        expect(authRepository.loginCount, 1);
        expect(client.connectedWithTokens, [testDeviceJwt, testRenewedDeviceJwt]);
      },
    );

    blocTest<DeviceRealtimeBloc, DeviceRealtimeState>(
      'a stable connection resets the count, for UNAVAILABLE too',
      build: buildBloc,
      act: (bloc) async {
        await connected(bloc);
        await unavailable();
        await elapseNext();
        await client.emit(const RealtimeConnected());
        timers.elapse(const Duration(seconds: 31)); // stable
        await unavailable();
        expect(nextDelay(), const Duration(seconds: 15));
      },
    );

    test('17. an intentional close leaves no socket and no timer behind',
        () async {
      final bloc = buildBloc();
      await connected(bloc);
      await unavailable();
      expect(timers.pending, hasLength(1));

      await bloc.close();
      timers.elapse(const Duration(minutes: 5));
      await FakeDeviceRealtimeClient.pump();

      expect(client.disposeCount, 1);
      expect(timers.pending, isEmpty);
      expect(client.connectedWithTokens, [testDeviceJwt]);
    });
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
