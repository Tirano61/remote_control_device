import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/config/app_config.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/network/api_client.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/data/datasources/device_auth_remote_data_source.dart';
import 'package:remote_control_device/features/device/data/datasources/device_enrollment_remote_data_source.dart';
import 'package:remote_control_device/features/device/data/repositories/device_auth_repository_impl.dart';
import 'package:remote_control_device/features/device/data/repositories/device_enrollment_repository_impl.dart';
import 'package:remote_control_device/features/device/domain/entities/device_activation.dart';
import 'package:remote_control_device/features/device/domain/entities/device_identity.dart';
import 'package:remote_control_device/features/device/domain/entities/device_session.dart';
import 'package:remote_control_device/features/device/domain/entities/device_technical_info.dart';

import '../../../fakes/device_fakes.dart';

/// Records what the client actually put on the wire and replays a canned
/// response, so the request shape can be checked against
/// `docs/backend/ENDPOINTS.md` without a running backend.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({required this.statusCode, required this.body});

  int statusCode;
  Map<String, dynamic> body;

  RequestOptions? lastRequest;
  Object? lastRequestData;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    lastRequestData = options.data;
    return ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const config = AppConfig(backendBaseUrl: 'http://backend.test:3000');

  late _RecordingAdapter adapter;
  late InMemoryDeviceTokenStore tokenStore;
  late ApiClient apiClient;

  void buildClient({
    int statusCode = 200,
    Map<String, dynamic> body = const <String, dynamic>{},
  }) {
    adapter = _RecordingAdapter(statusCode: statusCode, body: body);
    tokenStore = InMemoryDeviceTokenStore();
    apiClient = ApiClient(config: config, tokenStore: tokenStore)
      ..dio.httpClientAdapter = adapter;
  }

  Map<String, dynamic> sentBody() =>
      Map<String, dynamic>.from(adapter.lastRequestData! as Map);

  group('POST /device-enrollment/activate', () {
    const activationBody = {
      'activated': true,
      'deviceId': testDeviceId,
      'publicId': testPublicId,
      'name': testDeviceName,
      'deviceSecret': testDeviceSecret,
    };

    test('posts the documented path and body, with no Authorization header', () async {
      buildClient(body: activationBody);
      final repository = DeviceEnrollmentRepositoryImpl(
        DeviceEnrollmentRemoteDataSourceImpl(apiClient),
      );

      final result = await repository.activate(
        publicId: testPublicId,
        code: '418902',
        technicalInfo: const DeviceTechnicalInfo(
          manufacturer: 'Samsung',
          model: 'SM-X210',
          androidVersion: '14',
          appVersion: '1.0.0',
        ),
      );

      expect(result, isA<Ok<DeviceActivation>>());
      expect(adapter.lastRequest!.method, 'POST');
      expect(adapter.lastRequest!.path, '/device-enrollment/activate');
      expect(adapter.lastRequest!.headers.containsKey('Authorization'), isFalse);
      expect(sentBody(), {
        'publicId': testPublicId,
        'code': '418902',
        'manufacturer': 'Samsung',
        'model': 'SM-X210',
        'androidVersion': '14',
        'appVersion': '1.0.0',
      });
    });

    test('omits unavailable technical info instead of sending empty strings', () async {
      // The backend validates with forbidNonWhitelisted and a minimum length
      // of 1 on every optional field: an empty value would fail the request.
      buildClient(body: activationBody);
      final repository = DeviceEnrollmentRepositoryImpl(
        DeviceEnrollmentRemoteDataSourceImpl(apiClient),
      );

      await repository.activate(
        publicId: testPublicId,
        code: '418902',
        technicalInfo: const DeviceTechnicalInfo(
          manufacturer: '   ',
          appVersion: '1.0.0',
        ),
      );

      expect(sentBody().keys, unorderedEquals(['publicId', 'code', 'appVersion']));
    });

    test('maps 401 to AuthFailure', () async {
      buildClient(statusCode: 401, body: const {'message': 'Unauthorized'});
      final repository = DeviceEnrollmentRepositoryImpl(
        DeviceEnrollmentRemoteDataSourceImpl(apiClient),
      );

      final result = await repository.activate(
        publicId: testPublicId,
        code: '000000',
        technicalInfo: DeviceTechnicalInfo.empty,
      );

      expect(result.failureOrNull, isA<AuthFailure>());
    });

    test('maps 400 to ValidationFailure', () async {
      buildClient(statusCode: 400, body: const {'message': 'Bad Request'});
      final repository = DeviceEnrollmentRepositoryImpl(
        DeviceEnrollmentRemoteDataSourceImpl(apiClient),
      );

      final result = await repository.activate(
        publicId: 'nope',
        code: '1',
        technicalInfo: DeviceTechnicalInfo.empty,
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
    });
  });

  group('POST /device-auth/login', () {
    const loginBody = {
      'id': testDeviceId,
      'publicId': testPublicId,
      'name': testDeviceName,
      'isActive': true,
      'token': testDeviceJwt,
    };

    DeviceAuthRepositoryImpl buildRepository() => DeviceAuthRepositoryImpl(
      remoteDataSource: DeviceAuthRemoteDataSourceImpl(apiClient),
      tokenStore: tokenStore,
    );

    test('sends only deviceId + deviceSecret and keeps the JWT in memory', () async {
      buildClient(body: loginBody);

      final result = await buildRepository().login(testCredentials);

      expect(adapter.lastRequest!.path, '/device-auth/login');
      // publicId does not authenticate and the endpoint rejects extra fields.
      expect(sentBody(), {
        'deviceId': testDeviceId,
        'deviceSecret': testDeviceSecret,
      });
      expect(adapter.lastRequest!.headers.containsKey('Authorization'), isFalse);
      expect(result.valueOrNull, isA<DeviceSession>());
      expect(tokenStore.token, testDeviceJwt);
    });

    test('maps 401 to AuthFailure and installs no token', () async {
      buildClient(statusCode: 401, body: const {'message': 'Unauthorized'});

      final result = await buildRepository().login(testCredentials);

      expect(result.failureOrNull, isA<AuthFailure>());
      expect(tokenStore.hasToken, isFalse);
    });

    test('endSession drops the JWT without touching the credential', () async {
      buildClient(body: loginBody);
      final repository = buildRepository();

      await repository.login(testCredentials);
      expect(tokenStore.hasToken, isTrue);

      repository.endSession();
      expect(tokenStore.hasToken, isFalse);
    });
  });

  group('GET /device-auth/check-status', () {
    const statusBody = {
      'id': testDeviceId,
      'publicId': testPublicId,
      'name': testDeviceName,
      'isActive': true,
    };

    test('sends the Device JWT as a bearer token', () async {
      buildClient(body: statusBody);
      tokenStore.save(testDeviceJwt);
      final repository = DeviceAuthRepositoryImpl(
        remoteDataSource: DeviceAuthRemoteDataSourceImpl(apiClient),
        tokenStore: tokenStore,
      );

      final result = await repository.checkStatus();

      expect(adapter.lastRequest!.method, 'GET');
      expect(adapter.lastRequest!.path, '/device-auth/check-status');
      expect(
        adapter.lastRequest!.headers['Authorization'],
        'Bearer $testDeviceJwt',
      );
      expect(result.valueOrNull, isA<DeviceIdentity>());
      expect(result.valueOrNull?.publicId, testPublicId);
      // The contract states this endpoint does not renew the token.
      expect(statusBody.containsKey('token'), isFalse);
    });

    test('maps 401 to AuthFailure', () async {
      buildClient(statusCode: 401, body: const {'message': 'Unauthorized'});
      tokenStore.save(testDeviceJwt);
      final repository = DeviceAuthRepositoryImpl(
        remoteDataSource: DeviceAuthRemoteDataSourceImpl(apiClient),
        tokenStore: tokenStore,
      );

      final result = await repository.checkStatus();

      expect(result.failureOrNull, isA<AuthFailure>());
    });

    test('maps 500 to ServerFailure', () async {
      buildClient(statusCode: 500, body: const {'message': 'boom'});
      tokenStore.save(testDeviceJwt);
      final repository = DeviceAuthRepositoryImpl(
        remoteDataSource: DeviceAuthRemoteDataSourceImpl(apiClient),
        tokenStore: tokenStore,
      );

      expect((await repository.checkStatus()).failureOrNull, isA<ServerFailure>());
    });
  });
}
