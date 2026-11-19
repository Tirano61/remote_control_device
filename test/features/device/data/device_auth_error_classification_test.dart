import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/config/app_config.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/network/api_client.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/core/session/device_credential_revocation.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/data/datasources/device_auth_remote_data_source.dart';
import 'package:remote_control_device/features/device/data/network/authenticated_device_request.dart';
import 'package:remote_control_device/features/device/data/repositories/device_auth_repository_impl.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/support/data/datasources/support_remote_data_source.dart';
import 'package:remote_control_device/features/support/data/repositories/support_repository_impl.dart';

import '../../../fakes/device_fakes.dart';

/// Prompt 32's investigation, kept as permanent regressions: what the client
/// concludes from every answer a backend — or something in front of it, such
/// as a private dev tunnel — can give.
///
/// Everything runs against real `dart:io` servers on the loopback interface,
/// through the production `ApiClient` (real Dio, real IO adapter, real redirect
/// policy). The credentials are the fictitious fixtures; nothing leaves the
/// machine.
void main() {
  late _Server backend;
  late InMemoryDeviceTokenStore tokenStore;
  late ApiClient apiClient;
  late DeviceAuthRepositoryImpl authRepository;

  setUp(() async {
    backend = await _Server.start();
    tokenStore = InMemoryDeviceTokenStore();
    apiClient = ApiClient(
      config: AppConfig(
        backendBaseUrl: backend.url,
        connectTimeout: const Duration(seconds: 2),
        sendTimeout: const Duration(seconds: 2),
        receiveTimeout: const Duration(milliseconds: 400),
      ),
      tokenStore: tokenStore,
    );
    authRepository = DeviceAuthRepositoryImpl(
      remoteDataSource: DeviceAuthRemoteDataSourceImpl(apiClient),
      tokenStore: tokenStore,
    );
  });

  tearDown(() async {
    apiClient.dio.close(force: true);
    await backend.close();
  });

  const loginPath = DeviceAuthRemoteDataSourceImpl.loginPath;
  const checkStatusPath = DeviceAuthRemoteDataSourceImpl.checkStatusPath;

  const rejectionBody = {
    'statusCode': 401,
    'code': 'DEVICE_CREDENTIAL_REJECTED',
    'message': 'Invalid device credentials',
    'error': 'Unauthorized',
  };

  const loginBody = {
    'id': testDeviceId,
    'publicId': testPublicId,
    'name': testDeviceName,
    'isActive': true,
    'token': testDeviceJwt,
  };

  const statusBody = {
    'id': testDeviceId,
    'publicId': testPublicId,
    'name': testDeviceName,
    'isActive': true,
  };

  group('POST /device-auth/login', () {
    test('P35: a 200 that arrives after authorisation was withdrawn installs '
        'no token', () async {
      final answer = Completer<void>();
      backend.on(loginPath, (request) async {
        await answer.future;
        await _json(200, loginBody)(request);
      });

      final login = authRepository.login(testCredentials);
      // While the login is on the wire, a confirmed refusal (or a stop, or a
      // newer attempt) withdraws authorisation.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      tokenStore.clear();
      answer.complete();

      expect(await login, isA<Ok<Object?>>());
      expect(tokenStore.token, isNull);
    });

    test('a login started after a withdrawal installs its token normally',
        () async {
      tokenStore.clear();
      backend.on(loginPath, _json(200, loginBody));

      await authRepository.login(testCredentials);

      expect(tokenStore.token, testDeviceJwt);
    });

    test('1. 200 with the documented body authenticates', () async {
      backend.on(loginPath, _json(200, loginBody));

      final result = await authRepository.login(testCredentials);

      expect(result, isA<Ok<Object?>>());
      expect(tokenStore.token, testDeviceJwt);
    });

    test('2. 401 with DEVICE_CREDENTIAL_REJECTED is the confirmed rejection',
        () async {
      backend.on(loginPath, _json(401, rejectionBody));

      final result = await authRepository.login(testCredentials);

      expect(result.failureOrNull, isA<CredentialRejectedFailure>());
      expect(tokenStore.hasToken, isFalse);
    });

    test('the code alone decides it: message and error are not read', () async {
      backend.on(
        loginPath,
        _json(401, {'code': 'DEVICE_CREDENTIAL_REJECTED'}),
      );

      expect(
        (await authRepository.login(testCredentials)).failureOrNull,
        isA<CredentialRejectedFailure>(),
      );
    });

    final ambiguous = <String, _Handler>{
      '3. a 401 HTML page (private dev tunnel)': _raw(
        401,
        '<!DOCTYPE html><html><body>Unauthorized - sign in</body></html>',
        contentType: 'text/html; charset=utf-8',
      ),
      '4. an empty 401': _raw(401, ''),
      '5. a 401 JSON with no code (NestJS default)': _json(401, {
        'statusCode': 401,
        'message': 'Unauthorized',
      }),
      'a 401 JSON whose message says the right words': _json(401, {
        'statusCode': 401,
        'message': 'Invalid device credentials',
        'error': 'Unauthorized',
      }),
      'a 401 JSON with another code': _json(401, {'code': 'SOMETHING_ELSE'}),
      'a 401 whose code is not a string': _json(401, {'code': 401}),
      'a 401 JSON array': _raw(
        401,
        '["DEVICE_CREDENTIAL_REJECTED"]',
        contentType: 'application/json',
      ),
      'the right JSON served as text/plain': _raw(
        401,
        jsonEncode(rejectionBody),
        contentType: 'text/plain',
      ),
      'a malformed JSON 401': _raw(
        401,
        '{"code": "DEVICE_CREDENTIAL_REJECTED"',
        contentType: 'application/json',
      ),
    };

    for (final MapEntry(key: name, value: handler) in ambiguous.entries) {
      test('$name is ambiguous, never a rejection', () async {
        backend.on(loginPath, handler);

        final failure = (await authRepository.login(testCredentials))
            .failureOrNull;

        expect(failure, isNotNull);
        expect(failure, isNot(isA<CredentialRejectedFailure>()));
        expect(tokenStore.hasToken, isFalse);
      });
    }

    test('the code on another status is not a rejection either', () async {
      backend.on(loginPath, _json(403, rejectionBody));

      expect(
        (await authRepository.login(testCredentials)).failureOrNull,
        isA<ServerFailure>(),
      );
    });

    test('a 200 HTML page authenticates nothing', () async {
      backend.on(
        loginPath,
        _raw(200, '<html>Sign in</html>', contentType: 'text/html'),
      );

      expect(
        (await authRepository.login(testCredentials)).failureOrNull,
        isA<ServerFailure>(),
      );
      expect(tokenStore.hasToken, isFalse);
    });

    test('a 200 JSON without a token authenticates nothing', () async {
      backend.on(loginPath, _json(200, statusBody));

      expect(
        (await authRepository.login(testCredentials)).failureOrNull,
        isA<ServerFailure>(),
      );
      expect(tokenStore.hasToken, isFalse);
    });

    for (final status in [302, 303, 307]) {
      test('a $status is not followed, even to a valid-looking login', () async {
        backend
          ..on(loginPath, _redirect(status, '/elsewhere'))
          ..on('/elsewhere', _json(200, loginBody));

        final failure = (await authRepository.login(testCredentials))
            .failureOrNull;

        expect(failure, isA<ServerFailure>());
        expect(backend.hits('/elsewhere'), 0);
        expect(tokenStore.hasToken, isFalse);
      });
    }

    for (final status in [500, 502, 503]) {
      test('12. HTTP $status is a server error, not a rejection', () async {
        backend.on(loginPath, _json(status, {'statusCode': status}));

        expect(
          (await authRepository.login(testCredentials)).failureOrNull,
          isA<ServerFailure>(),
        );
      });
    }

    test('11. a backend that never answers times out as a network failure',
        () async {
      backend.on(loginPath, _hang);

      expect(
        (await authRepository.login(testCredentials)).failureOrNull,
        isA<NetworkFailure>(),
      );
    });

    test('14. nothing listening is a network failure', () async {
      await backend.close();

      expect(
        (await authRepository.login(testCredentials)).failureOrNull,
        isA<NetworkFailure>(),
      );
    });
  });

  group('GET /device-auth/check-status', () {
    setUp(() => tokenStore.save(testDeviceJwt));

    test('a 401 is AuthFailure — never a rejection, whatever the body', () async {
      // Even the login's code means nothing on this route.
      backend.on(checkStatusPath, _json(401, rejectionBody));

      expect(
        (await authRepository.checkStatus()).failureOrNull,
        isA<AuthFailure>(),
      );
    });

    test('9. a 302 to the same host is not followed', () async {
      backend
        ..on(checkStatusPath, _redirect(302, '/tunnel-sign-in'))
        ..on('/tunnel-sign-in', _json(200, statusBody));

      final failure = (await authRepository.checkStatus()).failureOrNull;

      expect(failure, isA<ServerFailure>());
      expect(backend.hits('/tunnel-sign-in'), 0);
    });

    test('10. a 302 to another origin is not followed and the Bearer token '
        'never reaches it', () async {
      final other = await _Server.start();
      addTearDown(other.close);
      other.on('/login', _raw(401, '<html>sign in</html>'));
      backend.on(checkStatusPath, _redirect(302, '${other.url}/login'));

      final failure = (await authRepository.checkStatus()).failureOrNull;

      expect(failure, isA<ServerFailure>());
      expect(other.requests, isEmpty);
      // The backend did get the token: it is the one it was meant for.
      expect(
        backend.requests.single.headers.value('authorization'),
        'Bearer $testDeviceJwt',
      );
    });
  });

  group('an authenticated REST call, end to end over HTTP', () {
    late FakeDeviceCredentialsStorage storage;
    late DeviceCredentialRevocation revocation;
    late SupportRepositoryImpl supportRepository;
    late List<void> reports;
    late StreamSubscription<void> subscription;

    const currentPath = SupportRemoteDataSourceImpl.currentPath;

    setUp(() {
      storage = FakeDeviceCredentialsStorage(testCredentials);
      revocation = DeviceCredentialRevocation();
      reports = [];
      subscription = revocation.revocations.listen(reports.add);
      supportRepository = SupportRepositoryImpl(
        remoteDataSource: SupportRemoteDataSourceImpl(apiClient),
        authenticatedRequest: AuthenticatedDeviceRequest(
          renewDeviceToken: RenewDeviceToken(
            loadDeviceCredentials: LoadDeviceCredentials(storage),
            authenticateDevice: AuthenticateDevice(authRepository),
          ),
          revocation: revocation,
        ),
      );
      tokenStore.save(testDeviceJwt);
    });

    tearDown(() async {
      await subscription.cancel();
      await revocation.dispose();
    });

    Future<Failure?> callAndSettle() async {
      final failure = (await supportRepository.current()).failureOrNull;
      await Future<void>.delayed(Duration.zero);
      return failure;
    }

    test('a GET answered 302 → 401 page triggers no login and wipes nothing',
        () async {
      // Exactly the Prompt 32 chain: authenticated GET → 302 → tunnel → 401.
      backend
        ..on(currentPath, _redirect(302, '/tunnel'))
        ..on('/tunnel', _raw(401, '<html>Unauthorized</html>'));

      final failure = await callAndSettle();

      expect(failure, isA<ServerFailure>());
      expect(backend.hits('/tunnel'), 0);
      expect(backend.hits(loginPath), 0);
      expect(reports, isEmpty);
      expect(storage.credentials, testCredentials);
      expect(storage.clearCount, 0);
    });

    test('a 401 whose renewal gets the HTML 401 is not reported', () async {
      backend
        ..on(currentPath, _json(401, {'statusCode': 401}))
        ..on(loginPath, _raw(401, '<html>Unauthorized</html>'));

      final failure = await callAndSettle();

      expect(failure, isA<AuthFailure>());
      expect(backend.hits(loginPath), 1);
      expect(reports, isEmpty);
      expect(storage.credentials, testCredentials);
    });

    test('a 401 whose renewal gets DEVICE_CREDENTIAL_REJECTED is reported '
        'once, and still wipes nothing', () async {
      backend
        ..on(currentPath, _json(401, {'statusCode': 401}))
        ..on(loginPath, _json(401, rejectionBody));

      final failure = await callAndSettle();

      expect(failure, isA<CredentialRejectedFailure>());
      expect(reports, hasLength(1));
      expect(backend.hits(currentPath), 1);
      expect(storage.credentials, testCredentials);
      expect(storage.clearCount, 0);
    });

    test('a 401 whose renewal succeeds is retried once with the new token',
        () async {
      var calls = 0;
      backend
        ..on(currentPath, (request) {
          calls++;
          return calls == 1
              ? _json(401, {'statusCode': 401})(request)
              : _json(200, {'supportRequest': null})(request);
        })
        ..on(loginPath, _json(200, {...loginBody, 'token': testRenewedDeviceJwt}));

      final result = await supportRepository.current();

      expect(result, isA<Ok<Object?>>());
      expect(
        backend.requests
            .where((r) => r.uri.path == currentPath)
            .map((r) => r.headers.value('authorization'))
            .toList(),
        ['Bearer $testDeviceJwt', 'Bearer $testRenewedDeviceJwt'],
      );
      // The public login never carries a Bearer token.
      expect(
        backend.requests
            .singleWhere((r) => r.uri.path == loginPath)
            .headers
            .value('authorization'),
        isNull,
      );
      expect(reports, isEmpty);
    });
  });
}

typedef _Handler = FutureOr<void> Function(HttpRequest request);

_Handler _json(int status, Object body) => _raw(
  status,
  jsonEncode(body),
  contentType: 'application/json; charset=utf-8',
);

_Handler _raw(int status, String body, {String? contentType}) => (request) {
  request.response.statusCode = status;
  if (contentType != null) {
    request.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
  }
  request.response.write(body);
  return request.response.close();
};

_Handler _redirect(int status, String location) => (request) {
  request.response
    ..statusCode = status
    ..headers.set(HttpHeaders.locationHeader, location);
  return request.response.close();
};

/// Accepts the request and never answers it.
Future<void> _hang(HttpRequest request) => Completer<void>().future;

/// A loopback HTTP server that answers each path with a configured handler and
/// records what it was sent.
class _Server {
  _Server._(this._server) {
    _server.listen((request) async {
      // Drain the body so the client is not left writing into nothing.
      await request.drain<void>();
      requests.add(_Recorded(request.uri, request.headers));
      final handler = _handlers[request.uri.path];
      if (handler == null) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      await handler(request);
    });
  }

  static Future<_Server> start() async =>
      _Server._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final Map<String, _Handler> _handlers = {};
  final List<_Recorded> requests = [];

  String get url => 'http://${_server.address.address}:${_server.port}';

  void on(String path, _Handler handler) => _handlers[path] = handler;

  int hits(String path) => requests.where((r) => r.uri.path == path).length;

  Future<void> close() => _server.close(force: true);
}

class _Recorded {
  _Recorded(this.uri, this.headers);

  final Uri uri;
  final HttpHeaders headers;
}
