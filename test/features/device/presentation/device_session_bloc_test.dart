import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/check_device_status.dart';
import 'package:remote_control_device/features/device/domain/usecases/clear_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';

import '../../../fakes/device_fakes.dart';

void main() {
  late FakeDeviceCredentialsStorage storage;
  late FakeDeviceAuthRepository authRepository;

  // The bloc is exercised through the real use cases; only the ports at the
  // edges (secure storage, HTTP repositories) are faked.
  DeviceSessionBloc buildBloc() => DeviceSessionBloc(
    loadDeviceCredentials: LoadDeviceCredentials(storage),
    authenticateDevice: AuthenticateDevice(authRepository),
    checkDeviceStatus: CheckDeviceStatus(authRepository),
    clearDeviceCredentials: ClearDeviceCredentials(
      credentialsStorage: storage,
      authRepository: authRepository,
    ),
  );

  setUp(() {
    storage = FakeDeviceCredentialsStorage();
    authRepository = FakeDeviceAuthRepository();
  });

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
      },
    );
  });

  group('startup already enrolled', () {
    setUp(() => storage.credentials = testCredentials);

    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'logs in automatically, checks status and becomes ready',
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
        // The backend is authoritative, but it did not reject anything here.
        expect(storage.clearCount, 0);
        expect(storage.credentials, testCredentials);
      },
    );

    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'check-status is what promotes to ready, not a successful login alone',
      build: buildBloc,
      seed: () => const DeviceSessionInitial(),
      act: (bloc) {
        authRepository.checkStatusResult = statusUnreachable;
        bloc.add(const DeviceSessionStarted());
      },
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticating(),
        DeviceSessionNetworkError(NetworkFailure()),
      ],
    );
  });

  group('revoked or rejected credential', () {
    setUp(() => storage.credentials = testCredentials);

    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'login 401 wipes the credential and requires re-enrollment',
      build: buildBloc,
      act: (bloc) {
        authRepository.loginResult = loginUnauthorized;
        bloc.add(const DeviceSessionStarted());
      },
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticating(),
        DeviceSessionReEnrollmentRequired(),
      ],
      verify: (_) {
        expect(storage.clearCount, 1);
        expect(storage.credentials, isNull);
        // The temporary Device JWT is dropped together with the credential.
        expect(authRepository.endSessionCount, 1);
        // No retry loop against a revoked secret.
        expect(authRepository.loginCount, 1);
      },
    );

    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'check-status 401 also wipes the credential',
      build: buildBloc,
      act: (bloc) {
        authRepository.checkStatusResult = statusUnauthorized;
        bloc.add(const DeviceSessionStarted());
      },
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticating(),
        DeviceSessionReEnrollmentRequired(),
      ],
      verify: (_) {
        expect(storage.clearCount, 1);
        expect(storage.credentials, isNull);
      },
    );
  });

  group('backend unreachable', () {
    setUp(() => storage.credentials = testCredentials);

    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'network failure keeps the credential and stays retryable',
      build: buildBloc,
      act: (bloc) {
        authRepository.loginResult = loginUnreachable;
        bloc.add(const DeviceSessionStarted());
      },
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticating(),
        DeviceSessionNetworkError(NetworkFailure()),
      ],
      verify: (_) {
        expect(storage.clearCount, 0);
        expect(storage.credentials, testCredentials);
        expect(authRepository.endSessionCount, 0);
      },
    );

    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'retry after the backend comes back reaches ready',
      build: buildBloc,
      act: (bloc) async {
        authRepository.loginResult = loginUnreachable;
        bloc.add(const DeviceSessionStarted());
        await Future<void>.delayed(Duration.zero);
        authRepository.loginResult = const Ok(testSession);
        bloc.add(const DeviceSessionRetryRequested());
      },
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticating(),
        DeviceSessionNetworkError(NetworkFailure()),
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticating(),
        DeviceSessionReady(testIdentity),
      ],
      verify: (_) => expect(storage.credentials, testCredentials),
    );

    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'a server error is retryable too and never wipes the credential',
      build: buildBloc,
      act: (bloc) {
        authRepository.loginResult = const Err(ServerFailure());
        bloc.add(const DeviceSessionStarted());
      },
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionAuthenticating(),
        DeviceSessionNetworkError(ServerFailure()),
      ],
      verify: (_) => expect(storage.clearCount, 0),
    );
  });

  group('secure storage failure', () {
    blocTest<DeviceSessionBloc, DeviceSessionState>(
      'an unreadable store is not mistaken for "not enrolled"',
      build: buildBloc,
      act: (bloc) {
        storage.failOnRead = true;
        bloc.add(const DeviceSessionStarted());
      },
      expect: () => const [
        DeviceSessionCheckingLocalCredentials(),
        DeviceSessionNetworkError(StorageFailure()),
      ],
      verify: (_) => expect(authRepository.loginCount, 0),
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
