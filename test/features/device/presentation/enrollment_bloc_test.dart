import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/features/device/domain/entities/device_technical_info.dart';
import 'package:remote_control_device/features/device/domain/usecases/enroll_device.dart';
import 'package:remote_control_device/features/device/presentation/bloc/enrollment/enrollment_bloc.dart';

import '../../../fakes/device_fakes.dart';

void main() {
  late FakeDeviceEnrollmentRepository repository;
  late FakeDeviceCredentialsStorage storage;
  late FakeDeviceInfoProvider deviceInfoProvider;

  EnrollmentBloc buildBloc() => EnrollmentBloc(
    enrollDevice: EnrollDevice(
      repository: repository,
      credentialsStorage: storage,
      deviceInfoProvider: deviceInfoProvider,
    ),
  );

  setUp(() {
    repository = FakeDeviceEnrollmentRepository();
    storage = FakeDeviceCredentialsStorage();
    deviceInfoProvider = FakeDeviceInfoProvider(
      const DeviceTechnicalInfo(
        manufacturer: 'Samsung',
        model: 'SM-X210',
        androidVersion: '14',
        appVersion: '1.0.0',
      ),
    );
  });

  group('successful activation', () {
    blocTest<EnrollmentBloc, EnrollmentState>(
      'stores deviceId + deviceSecret and reports only public data',
      build: buildBloc,
      act: (bloc) => bloc.add(
        const EnrollmentSubmitted(publicId: testPublicId, code: '418902'),
      ),
      expect: () => const [
        EnrollmentSubmitting(),
        EnrollmentSuccess(publicId: testPublicId, name: testDeviceName),
      ],
      verify: (_) {
        expect(storage.saveCount, 1);
        expect(storage.credentials?.deviceId, testDeviceId);
        expect(storage.credentials?.deviceSecret, testDeviceSecret);
      },
    );

    blocTest<EnrollmentBloc, EnrollmentState>(
      'sends the technical info collected from the device',
      build: buildBloc,
      act: (bloc) => bloc.add(
        const EnrollmentSubmitted(publicId: testPublicId, code: '418902'),
      ),
      verify: (_) {
        expect(deviceInfoProvider.collectCount, 1);
        expect(repository.lastPublicId, testPublicId);
        expect(repository.lastCode, '418902');
        expect(repository.lastTechnicalInfo?.manufacturer, 'Samsung');
        expect(repository.lastTechnicalInfo?.androidVersion, '14');
      },
    );

    blocTest<EnrollmentBloc, EnrollmentState>(
      'never exposes the deviceSecret through bloc state',
      build: buildBloc,
      act: (bloc) => bloc.add(
        const EnrollmentSubmitted(publicId: testPublicId, code: '418902'),
      ),
      verify: (bloc) {
        expect(bloc.state.toString(), isNot(contains(testDeviceSecret)));
      },
    );
  });

  group('rejected activation', () {
    setUp(() => repository.result = activationUnauthorized);

    blocTest<EnrollmentBloc, EnrollmentState>(
      'a 401 fails the form and stores nothing',
      build: buildBloc,
      act: (bloc) => bloc.add(
        const EnrollmentSubmitted(publicId: testPublicId, code: '000000'),
      ),
      expect: () => const [
        EnrollmentSubmitting(),
        EnrollmentFailure(AuthFailure()),
      ],
      verify: (_) {
        expect(storage.saveCount, 0);
        expect(storage.credentials, isNull);
      },
    );
  });

  group('backend unreachable during activation', () {
    setUp(() => repository.result = activationUnreachable);

    blocTest<EnrollmentBloc, EnrollmentState>(
      'a network failure is reported without storing anything',
      build: buildBloc,
      act: (bloc) => bloc.add(
        const EnrollmentSubmitted(publicId: testPublicId, code: '418902'),
      ),
      expect: () => const [
        EnrollmentSubmitting(),
        EnrollmentFailure(NetworkFailure()),
      ],
      verify: (_) => expect(storage.credentials, isNull),
    );
  });

  group('secure storage unavailable', () {
    blocTest<EnrollmentBloc, EnrollmentState>(
      'an activation whose credential cannot be stored is a failure',
      build: buildBloc,
      act: (bloc) {
        storage.failOnWrite = true;
        bloc.add(
          const EnrollmentSubmitted(publicId: testPublicId, code: '418902'),
        );
      },
      expect: () => const [
        EnrollmentSubmitting(),
        EnrollmentFailure(StorageFailure()),
      ],
      verify: (_) => expect(storage.credentials, isNull),
    );
  });

  blocTest<EnrollmentBloc, EnrollmentState>(
    'a second submit while one is in flight is ignored',
    build: buildBloc,
    act: (bloc) {
      bloc
        ..add(const EnrollmentSubmitted(publicId: testPublicId, code: '418902'))
        ..add(const EnrollmentSubmitted(publicId: testPublicId, code: '418902'));
    },
    expect: () => const [
      EnrollmentSubmitting(),
      EnrollmentSuccess(publicId: testPublicId, name: testDeviceName),
    ],
    verify: (_) => expect(repository.activateCount, 1),
  );
}
