import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/domain/entities/device_credentials.dart';
import 'package:remote_control_device/features/device/domain/entities/device_identity.dart';
import 'package:remote_control_device/features/device/domain/entities/device_session.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/check_device_status.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/suspend_device_authorization.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';

import '../../../fakes/device_fakes.dart';
import '../../../fakes/manual_timers.dart';

/// The startup decision against every answer the backend — or something in
/// front of it — can give. The rule under test, in each case:
///
/// * only a login **and** a check-status accepted by the backend reach READY;
/// * only `401 DEVICE_CREDENTIAL_REJECTED` on the login is a refusal;
/// * nothing, refusal included, wipes the stored credential.
void main() {
  late FakeDeviceCredentialsStorage storage;
  late InMemoryDeviceTokenStore tokenStore;
  late FakeDeviceAuthRepository authRepository;
  late ManualTimers timers;

  // The bloc is exercised through the real use cases; only the ports at the
  // edges (secure storage, HTTP repositories, the clock) are faked.
  DeviceSessionBloc buildBloc() => DeviceSessionBloc(
    loadDeviceCredentials: LoadDeviceCredentials(storage),
    authenticateDevice: AuthenticateDevice(authRepository),
    checkDeviceStatus: CheckDeviceStatus(authRepository),
    suspendDeviceAuthorization: SuspendDeviceAuthorization(authRepository),
    timerFactory: timers.factory,
  );

  const backoff = DeviceSessionBloc.defaultRetryBackoff;

  const statusRejectedToken = Err<DeviceIdentity>(AuthFailure());

  setUp(() {
    storage = FakeDeviceCredentialsStorage();
    tokenStore = InMemoryDeviceTokenStore();
    authRepository = FakeDeviceAuthRepository(tokenStore: tokenStore);
    timers = ManualTimers();
  });

  /// The credential is exactly where enrollment left it.
  void expectCredentialPreserved() {
    expect(storage.credentials, testCredentials);
    expect(storage.clearCount, 0);
  }

  group('startup without local credentials', () {
    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'empty secure storage ends in notEnrolled and never calls login',
      build: buildBloc,
      act: (bloc) => bloc.add(const DeviceSessionStarted()),
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionNotEnrolled(),
      ],
      verify: (_) {
        expect(authRepository.loginCount, 0);
        expect(authRepository.checkStatusCount, 0);
        expect(timers.pending, isEmpty);
      },
    );
  });

  group('1. confirmed authentication', () {
    setUp(() => storage.credentials = testCredentials);

    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'logs in, checks status with the new token and becomes ready',
      build: buildBloc,
      act: (bloc) => bloc.add(const DeviceSessionStarted()),
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticating(),
        DeviceSessionReady(testIdentity),
      ],
      verify: (_) {
        expect(authRepository.lastLoginCredentials, testCredentials);
        expect(authRepository.checkStatusCount, 1);
        expect(authRepository.checkStatusHadToken, [true]);
        expect(tokenStore.token, testDeviceJwt);
        expectCredentialPreserved();
        expect(timers.pending, isEmpty);
      },
    );

    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'check-status is what promotes to ready, not a successful login alone',
      build: buildBloc,
      act: (bloc) {
        authRepository.checkStatusResult = statusUnreachable;
        bloc.add(const DeviceSessionStarted());
      },
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticating(),
        DeviceSessionAuthenticationUnavailable(NetworkFailure()),
      ],
      // The token the login produced is not kept: it was never confirmed.
      verify: (_) => expect(tokenStore.hasToken, isFalse),
    );
  });

  group('2. login answered 401 DEVICE_CREDENTIAL_REJECTED', () {
    setUp(() => storage.credentials = testCredentials);

    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'withdraws authorisation, keeps the credential, retries nothing',
      build: buildBloc,
      act: (bloc) {
        authRepository.loginResult = loginRejected;
        bloc.add(const DeviceSessionStarted());
      },
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticating(),
        DeviceSessionCredentialRefused(),
      ],
      verify: (_) {
        expectCredentialPreserved();
        expect(tokenStore.hasToken, isFalse);
        expect(authRepository.endSessionCount, greaterThan(0));
        expect(authRepository.checkStatusCount, 0);
        // No timer at all: a confirmed refusal is not retried on its own.
        expect(timers.pending, isEmpty);
        timers.elapse(const Duration(hours: 1));
        expect(authRepository.loginCount, 1);
      },
    );
  });

  group('3-5. login answered a 401 that confirms nothing', () {
    setUp(() => storage.credentials = testCredentials);

    // HTML, empty or code-less 401 bodies all reach the domain as AuthFailure;
    // the data layer tests pin that mapping body by body.
    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'is "authentication unavailable", never a refusal',
      build: buildBloc,
      act: (bloc) {
        authRepository.loginResult = loginUnauthorized;
        bloc.add(const DeviceSessionStarted());
      },
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticating(),
        DeviceSessionAuthenticationUnavailable(AuthFailure()),
      ],
      verify: (_) {
        expectCredentialPreserved();
        expect(tokenStore.hasToken, isFalse);
        expect(authRepository.checkStatusCount, 0);
      },
    );
  });

  group('6-8. check-status answered 401', () {
    setUp(() => storage.credentials = testCredentials);

    blocTest<DeviceSessionBloc, DeviceSessionState>(
      '6. renews once and becomes ready with the renewed token',
      build: buildBloc,
      act: (bloc) {
        authRepository.loginQueue.addAll([
          const Ok(testSession),
          const Ok(testRenewedSession),
        ]);
        authRepository.checkStatusQueue.add(statusRejectedToken);
        bloc.add(const DeviceSessionStarted());
      },
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticating(),
        DeviceSessionReady(testIdentity),
      ],
      verify: (_) {
        expect(authRepository.loginCount, 2);
        expect(authRepository.checkStatusCount, 2);
        expect(tokenStore.token, testRenewedDeviceJwt);
        expectCredentialPreserved();
      },
    );

    blocTest<DeviceSessionBloc, DeviceSessionState>(
      '7. a renewal answered DEVICE_CREDENTIAL_REJECTED is a refusal',
      build: buildBloc,
      act: (bloc) {
        authRepository.loginQueue.addAll([const Ok(testSession), loginRejected]);
        authRepository.checkStatusQueue.add(statusRejectedToken);
        bloc.add(const DeviceSessionStarted());
      },
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticating(),
        DeviceSessionCredentialRefused(),
      ],
      verify: (_) {
        expectCredentialPreserved();
        expect(tokenStore.hasToken, isFalse);
        expect(authRepository.checkStatusCount, 1);
        expect(timers.pending, isEmpty);
      },
    );

    for (final (name, renewal) in [
      ('a code-less 401', loginUnauthorized),
      ('no network', loginUnreachable),
      ('a server error', const Err<DeviceSession>(ServerFailure())),
    ]) {
      blocTest<DeviceSessionBloc, DeviceSessionState>(
        '8. a renewal answered $name is unavailable, credential kept',
        build: buildBloc,
        act: (bloc) {
          authRepository.loginQueue.addAll([const Ok(testSession), renewal]);
          authRepository.checkStatusQueue.add(statusRejectedToken);
          bloc.add(const DeviceSessionStarted());
        },
        expect: () => [
          const DeviceSessionCheckingLocalCredentials(),
          const DeviceSessionAuthenticating(),
          DeviceSessionAuthenticationUnavailable(renewal.failure),
        ],
        verify: (_) {
          expectCredentialPreserved();
          expect(tokenStore.hasToken, isFalse);
        },
      );
    }

    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'a renewed token refused again stops after one renewal',
      build: buildBloc,
      act: (bloc) {
        authRepository.checkStatusResult = statusRejectedToken;
        bloc.add(const DeviceSessionStarted());
      },
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticating(),
        DeviceSessionAuthenticationUnavailable(AuthFailure()),
      ],
      verify: (_) {
        // Exactly one renewal: two logins, two checks, no loop.
        expect(authRepository.loginCount, 2);
        expect(authRepository.checkStatusCount, 2);
        expectCredentialPreserved();
        expect(tokenStore.hasToken, isFalse);
      },
    );
  });

  group('11-12. transport and server errors', () {
    setUp(() => storage.credentials = testCredentials);

    for (final (name, failure) in [
      ('a timeout', const NetworkFailure(debugDetail: 'receiveTimeout')),
      ('HTTP 500', const ServerFailure(debugDetail: '500')),
      ('HTTP 502', const ServerFailure(debugDetail: '502')),
      ('HTTP 503', const ServerFailure(debugDetail: '503')),
      ('a redirect', const ServerFailure(debugDetail: 'redirect 302')),
    ]) {
      blocTest<DeviceSessionBloc, DeviceSessionState>(
        'login answered $name is unavailable and keeps the credential',
        build: buildBloc,
        act: (bloc) {
          authRepository.loginResult = Err<DeviceSession>(failure);
          bloc.add(const DeviceSessionStarted());
        },
        expect: () => [
          const DeviceSessionCheckingLocalCredentials(),
          const DeviceSessionAuthenticating(),
          DeviceSessionAuthenticationUnavailable(failure),
        ],
        verify: (_) {
          expectCredentialPreserved();
          expect(authRepository.endSessionCount, greaterThan(0));
        },
      );
    }
  });

  group('14-15. connectivity lost, then back', () {
    setUp(() => storage.credentials = testCredentials);

    test('retries on a capped backoff and recovers by itself', () async {
      authRepository.loginResult = loginUnreachable;
      final bloc = buildBloc()..add(const DeviceSessionStarted());
      await pumpEventQueue();
      expect(bloc.state, isA<DeviceSessionAuthenticationUnavailable>());

      // 5 s, 10 s, 20 s, 40 s, then 60 s for as long as it takes.
      final seen = <Duration>[];
      for (var i = 0; i < 7; i++) {
        final next = timers.pending.single.dueAt - timers.now;
        seen.add(next);
        timers.elapse(next);
        await pumpEventQueue();
        expect(bloc.state, isA<DeviceSessionAuthenticationUnavailable>());
      }
      expect(seen, [...backoff, backoff.last, backoff.last]);
      expect(authRepository.loginCount, 8);
      expectCredentialPreserved();

      // The backend is reachable again.
      authRepository.loginResult = const Ok(testSession);
      timers.elapse(backoff.last);
      await pumpEventQueue();

      expect(bloc.state, const DeviceSessionReady(testIdentity));
      expect(timers.pending, isEmpty);
      await bloc.close();
    });

    test('a manual retry runs now and replaces the pending timer', () async {
      authRepository.loginResult = loginUnreachable;
      final bloc = buildBloc()..add(const DeviceSessionStarted());
      await pumpEventQueue();
      expect(timers.pending, hasLength(1));

      authRepository.loginResult = const Ok(testSession);
      bloc.add(const DeviceSessionRetryRequested());
      await pumpEventQueue();

      expect(bloc.state, const DeviceSessionReady(testIdentity));
      expect(timers.pending, isEmpty);
      expect(authRepository.loginCount, 2);
      await bloc.close();
    });

    test('closing the bloc cancels the pending retry', () async {
      authRepository.loginResult = loginUnreachable;
      final bloc = buildBloc()..add(const DeviceSessionStarted());
      await pumpEventQueue();
      await bloc.close();
      expect(timers.pending, isEmpty);
    });
  });

  group('16-18. refusal, reactivation, real revocation', () {
    setUp(() => storage.credentials = testCredentials);

    test('16-17. a deactivated device comes back with the same credential '
        'once reactivated', () async {
      // Deactivated by an admin: the login is refused.
      authRepository.loginResult = loginRejected;
      final bloc = buildBloc()..add(const DeviceSessionStarted());
      await pumpEventQueue();
      expect(bloc.state, const DeviceSessionCredentialRefused());

      // Reactivated. Nothing happens until someone asks.
      authRepository.loginResult = const Ok(testSession);
      timers.elapse(const Duration(hours: 1));
      await pumpEventQueue();
      expect(bloc.state, const DeviceSessionCredentialRefused());
      expect(authRepository.loginCount, 1);

      bloc.add(const DeviceSessionRetryRequested());
      await pumpEventQueue();

      expect(bloc.state, const DeviceSessionReady(testIdentity));
      expect(authRepository.lastLoginCredentials, testCredentials);
      expectCredentialPreserved();
      await bloc.close();
    });

    test('18. a really revoked credential stays refused on every retry and '
        'is never wiped', () async {
      authRepository.loginResult = loginRejected;
      final bloc = buildBloc()..add(const DeviceSessionStarted());
      await pumpEventQueue();

      for (var i = 0; i < 3; i++) {
        bloc.add(const DeviceSessionRetryRequested());
        await pumpEventQueue();
        expect(bloc.state, const DeviceSessionCredentialRefused());
      }

      expect(authRepository.loginCount, 4);
      expect(tokenStore.hasToken, isFalse);
      expectCredentialPreserved();
      expect(timers.pending, isEmpty);
      await bloc.close();
    });

    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'a rejection reported while ready withdraws authorisation at once',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceSessionStarted());
        await pumpEventQueue();
        bloc.add(const DeviceSessionCredentialRejected());
      },
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticating(),
        DeviceSessionReady(testIdentity),
        DeviceSessionCredentialRefused(),
      ],
      verify: (_) {
        expect(tokenStore.hasToken, isFalse);
        expectCredentialPreserved();
      },
    );

    test('a rejection reported mid-attempt is not overtaken by that '
        'attempt', () async {
      final bloc = buildBloc();
      final states = <DeviceSessionState>[];
      final subscription = bloc.stream.listen(states.add);

      // The login in flight would succeed; the report is the newer fact.
      bloc
        ..add(const DeviceSessionStarted())
        ..add(const DeviceSessionCredentialRejected());
      await pumpEventQueue();

      expect(states.last, const DeviceSessionCredentialRefused());
      expect(states, isNot(contains(isA<DeviceSessionReady>())));
      expect(tokenStore.hasToken, isFalse);
      await subscription.cancel();
      await bloc.close();
    });
  });

  group('20. secure storage', () {
    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'an unreadable store is not mistaken for "not enrolled"',
      build: buildBloc,
      act: (bloc) {
        storage.failOnRead = true;
        bloc.add(const DeviceSessionStarted());
      },
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticationUnavailable(StorageFailure()),
      ],
      verify: (_) {
        expect(authRepository.loginCount, 0);
        expect(storage.clearCount, 0);
      },
    );
  });

  group('21. voluntary re-enrollment', () {
    const newCredentials = DeviceCredentials(
      deviceId: testDeviceId,
      deviceSecret: 'ZyXwVuTsRqPoNmLkJiHgFeDcBa9876543210-_zy',
    );

    setUp(() => storage.credentials = testCredentials);

    test('is offered from a refusal, can be cancelled, and replaces the '
        'credential only by enrolling', () async {
      authRepository.loginResult = loginRejected;
      final bloc = buildBloc()..add(const DeviceSessionStarted());
      await pumpEventQueue();

      bloc.add(const DeviceSessionReEnrollmentRequested());
      await pumpEventQueue();
      expect(bloc.state, const DeviceSessionReEnrolling());
      // Opening the form changes nothing stored.
      expectCredentialPreserved();

      bloc.add(const DeviceSessionReEnrollmentCancelled());
      await pumpEventQueue();
      expect(bloc.state, const DeviceSessionCredentialRefused());
      expectCredentialPreserved();

      bloc.add(const DeviceSessionReEnrollmentRequested());
      await pumpEventQueue();
      // What `EnrollDevice` does on a successful activation.
      storage.credentials = newCredentials;
      authRepository.loginResult = const Ok(testSession);
      bloc.add(const DeviceSessionEnrollmentCompleted());
      await pumpEventQueue();

      expect(bloc.state, const DeviceSessionReady(testIdentity));
      expect(authRepository.lastLoginCredentials, newCredentials);
      expect(storage.clearCount, 0);
      await bloc.close();
    });

    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'is not offered to a device the backend accepts',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const DeviceSessionStarted());
        await pumpEventQueue();
        bloc.add(const DeviceSessionReEnrollmentRequested());
      },
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticating(),
        DeviceSessionReady(testIdentity),
      ],
    );
  });

  group('after enrollment', () {
    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'authenticates with the credential the enrollment flow just stored',
      build: buildBloc,
      act: (bloc) {
        storage.credentials = testCredentials;
        bloc.add(const DeviceSessionEnrollmentCompleted());
      },
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticating(),
        DeviceSessionReady(testIdentity),
      ],
      verify: (_) => expect(authRepository.lastLoginCredentials, testCredentials),
    );
  });
}
