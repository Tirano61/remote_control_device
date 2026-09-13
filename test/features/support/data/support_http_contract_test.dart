import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/config/app_config.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/network/api_client.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/core/session/device_credential_revocation.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/data/network/authenticated_device_request.dart';
import 'package:remote_control_device/features/device/domain/entities/device_credentials.dart';
import 'package:remote_control_device/features/device/domain/entities/device_identity.dart';
import 'package:remote_control_device/features/device/domain/entities/device_session.dart';
import 'package:remote_control_device/features/device/domain/repositories/device_auth_repository.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/support/data/datasources/support_remote_data_source.dart';
import 'package:remote_control_device/features/support/data/repositories/support_repository_impl.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request_status.dart';
import 'package:remote_control_device/features/support/domain/repositories/support_repository.dart';

import '../../../fakes/device_fakes.dart';
import '../../../fakes/support_fakes.dart';

/// One scripted HTTP reply.
class _Reply {
  const _Reply(this.statusCode, this.body);

  final int statusCode;
  final Map<String, dynamic> body;
}

/// Replays scripted replies and records exactly what went on the wire, so the
/// request shapes can be checked against `docs/backend/ENDPOINTS.md` without a
/// running backend.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.replies);

  /// Consumed in order; the last one repeats once the list runs out.
  final List<_Reply> replies;

  final List<RequestOptions> requests = [];
  int _served = 0;

  RequestOptions get lastRequest => requests.last;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final reply = replies[_served.clamp(0, replies.length - 1)];
    _served++;
    return ResponseBody.fromString(
      jsonEncode(reply.body),
      reply.statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A login that does not answer until the test lets it, so two calls can be
/// inside the renewal at the same time — which is the only way to observe that
/// they share one.
class _GatedAuthRepository implements DeviceAuthRepository {
  _GatedAuthRepository(this._tokenStore);

  final DeviceTokenStore _tokenStore;
  final Completer<void> gate = Completer<void>();

  int loginCount = 0;

  @override
  Future<Result<DeviceSession>> login(DeviceCredentials credentials) async {
    loginCount++;
    await gate.future;
    _tokenStore.save(testRenewedSession.token);
    return const Ok(testRenewedSession);
  }

  @override
  Future<Result<DeviceIdentity>> checkStatus() async => const Ok(testIdentity);

  @override
  void endSession() => _tokenStore.clear();
}

void main() {
  const config = AppConfig(backendBaseUrl: 'http://backend.test:3000');

  late _RecordingAdapter adapter;
  late InMemoryDeviceTokenStore tokenStore;
  late FakeDeviceCredentialsStorage storage;
  late FakeDeviceAuthRepository authRepository;
  late DeviceCredentialRevocation revocation;
  late SupportRepository repository;

  /// Builds the whole authenticated stack: the support endpoints answer from
  /// [replies], while the renewal that a `401` triggers goes through the same
  /// `RenewDeviceToken` the realtime layer uses.
  void build(List<_Reply> replies, {DeviceAuthRepository? renewingWith}) {
    adapter = _RecordingAdapter(replies);
    tokenStore = InMemoryDeviceTokenStore()..save(testDeviceJwt);
    storage = FakeDeviceCredentialsStorage(testCredentials);
    authRepository = FakeDeviceAuthRepository(
      loginResult: const Ok(testRenewedSession),
      tokenStore: tokenStore,
    );
    revocation = DeviceCredentialRevocation();

    final apiClient = ApiClient(config: config, tokenStore: tokenStore)
      ..dio.httpClientAdapter = adapter;

    repository = SupportRepositoryImpl(
      remoteDataSource: SupportRemoteDataSourceImpl(apiClient),
      authenticatedRequest: AuthenticatedDeviceRequest(
        renewDeviceToken: RenewDeviceToken(
          loadDeviceCredentials: LoadDeviceCredentials(storage),
          authenticateDevice: AuthenticateDevice(
            renewingWith ?? authRepository,
          ),
        ),
        revocation: revocation,
      ),
    );
  }

  tearDown(() async => revocation.dispose());

  /// Every device support endpoint takes its identity from the Device JWT. A
  /// `deviceId` anywhere on the wire would be both useless and a lie about
  /// where authority comes from.
  void expectNoDeviceIdentityOnTheWire(RequestOptions request) {
    expect(request.queryParameters, isEmpty);
    expect(request.data, isNull);
    expect(request.path, isNot(contains(testDeviceId)));
    expect(request.path, isNot(contains(testPublicId)));
  }

  group('POST /support-requests', () {
    test('posts the documented path with an empty body and the Device JWT', () async {
      build([_Reply(201, supportRequestJson())]);

      final result = await repository.create();

      expect(adapter.lastRequest.method, 'POST');
      expect(adapter.lastRequest.path, '/support-requests');
      expect(
        adapter.lastRequest.headers['Authorization'],
        'Bearer $testDeviceJwt',
      );
      expectNoDeviceIdentityOnTheWire(adapter.lastRequest);
      expect(result.valueOrNull?.status, SupportRequestStatus.waiting);
      expect(result.valueOrNull?.id, testSupportRequestId);
      expect(result.valueOrNull?.technician, isNull);
    });

    test('maps 409 — an active request already exists — to ConflictFailure', () async {
      build([const _Reply(409, {'message': 'conflict'})]);

      expect((await repository.create()).failureOrNull, isA<ConflictFailure>());
    });
  });

  group('GET /support-requests/current', () {
    test('reads the envelope and the technician block', () async {
      build([
        _Reply(
          200,
          currentEnvelope(
            supportRequestJson(status: 'ASSIGNED', withTechnician: true),
          ),
        ),
      ]);

      final result = await repository.current();

      expect(adapter.lastRequest.method, 'GET');
      expect(adapter.lastRequest.path, '/support-requests/current');
      expectNoDeviceIdentityOnTheWire(adapter.lastRequest);

      final request = result.valueOrNull;
      expect(request?.status, SupportRequestStatus.assigned);
      expect(request?.technician?.id, testTechnicianId);
      expect(request?.technician?.name, testTechnicianName);
    });

    test('a null supportRequest is a value, not a failure', () async {
      build([_Reply(200, currentEnvelope(null))]);

      final result = await repository.current();

      expect(result, isA<Ok<SupportRequest?>>());
      expect(result.valueOrNull, isNull);
    });

    test('a response without the documented envelope fails loudly', () async {
      build([const _Reply(200, {'unexpected': true})]);

      expect((await repository.current()).failureOrNull, isA<ServerFailure>());
    });

    test('an unknown future status is named, never guessed at', () async {
      build([
        _Reply(200, currentEnvelope(supportRequestJson(status: 'ESCALATED'))),
      ]);

      expect(
        (await repository.current()).valueOrNull?.status,
        SupportRequestStatus.unknown,
      );
    });
  });

  group('POST /support-requests/:id/accept', () {
    test('addresses the id from the backend and sends no body', () async {
      build([
        _Reply(200, supportRequestJson(status: 'ACCEPTED', withTechnician: true)),
      ]);

      final result = await repository.accept(testSupportRequestId);

      expect(adapter.lastRequest.method, 'POST');
      expect(
        adapter.lastRequest.path,
        '/support-requests/$testSupportRequestId/accept',
      );
      expectNoDeviceIdentityOnTheWire(adapter.lastRequest);
      expect(result.valueOrNull?.status, SupportRequestStatus.accepted);
    });

    test('maps 409 — not in ASSIGNED — to ConflictFailure', () async {
      build([const _Reply(409, {'message': 'conflict'})]);

      expect(
        (await repository.accept(testSupportRequestId)).failureOrNull,
        isA<ConflictFailure>(),
      );
    });

    test('maps 404 — unknown, or another device — to NotFoundFailure', () async {
      build([const _Reply(404, {'message': 'not found'})]);

      expect(
        (await repository.accept(testSupportRequestId)).failureOrNull,
        isA<NotFoundFailure>(),
      );
    });
  });

  group('POST /support-requests/:id/reject', () {
    test('answers the documented terminal status', () async {
      build([
        _Reply(200, supportRequestJson(status: 'REJECTED', withTechnician: true)),
      ]);

      final result = await repository.reject(testSupportRequestId);

      expect(
        adapter.lastRequest.path,
        '/support-requests/$testSupportRequestId/reject',
      );
      expectNoDeviceIdentityOnTheWire(adapter.lastRequest);
      expect(result.valueOrNull?.status, SupportRequestStatus.rejected);
    });
  });

  group('POST /support-requests/:id/cancel', () {
    test('answers the documented terminal status', () async {
      build([_Reply(200, supportRequestJson(status: 'CANCELLED'))]);

      final result = await repository.cancel(testSupportRequestId);

      expect(
        adapter.lastRequest.path,
        '/support-requests/$testSupportRequestId/cancel',
      );
      expectNoDeviceIdentityOnTheWire(adapter.lastRequest);
      expect(result.valueOrNull?.status, SupportRequestStatus.cancelled);
    });

    test('maps the 409 raised by a live remote session to ConflictFailure', () async {
      // The contract shares 409 between "already terminal" and "a session has
      // started"; the client re-reads state instead of parsing the message.
      build([const _Reply(409, {'message': 'conflict'})]);

      expect(
        (await repository.cancel(testSupportRequestId)).failureOrNull,
        isA<ConflictFailure>(),
      );
    });
  });

  group('an expired Device JWT', () {
    test('is renewed once and the call is repeated with the new token', () async {
      build([
        const _Reply(401, {'message': 'Unauthorized'}),
        _Reply(200, currentEnvelope(supportRequestJson())),
      ]);

      final result = await repository.current();

      expect(result.valueOrNull?.status, SupportRequestStatus.waiting);
      expect(authRepository.loginCount, 1);
      expect(adapter.requests, hasLength(2));
      // The point of the exercise: the second attempt presents the JWT the
      // renewal issued, not the one that was just refused.
      expect(
        adapter.requests.first.headers['Authorization'],
        'Bearer $testDeviceJwt',
      );
      expect(
        adapter.requests.last.headers['Authorization'],
        'Bearer $testRenewedDeviceJwt',
      );
      // Nothing was touched: this was a session artifact expiring, not a
      // credential being revoked.
      expect(storage.credentials, testCredentials);
      expect(storage.clearCount, 0);
    });

    test('renews at most once: a second 401 propagates instead of looping', () async {
      build([const _Reply(401, {'message': 'Unauthorized'})]);

      final result = await repository.create();

      expect(result.failureOrNull, isA<AuthFailure>());
      expect(authRepository.loginCount, 1);
      expect(adapter.requests, hasLength(2));
    });

    test('one renewal serves several calls that expire together', () async {
      final gated = _GatedAuthRepository(InMemoryDeviceTokenStore());
      build([
        const _Reply(401, {'message': 'Unauthorized'}),
        const _Reply(401, {'message': 'Unauthorized'}),
        _Reply(200, currentEnvelope(null)),
      ], renewingWith: gated);

      final pending = Future.wait([repository.current(), repository.current()]);
      // Both calls are inside the renewal by now; neither can proceed until the
      // login answers.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      gated.gate.complete();
      await pending;

      expect(gated.loginCount, 1);
    });
  });

  group('a revoked permanent credential', () {
    test('is reported once, and the failure stays an auth failure', () async {
      build([const _Reply(401, {'message': 'Unauthorized'})]);
      authRepository.loginResult = loginUnauthorized;

      final reported = expectLater(revocation.revocations, emits(isNull));
      final result = await repository.accept(testSupportRequestId);

      expect(result.failureOrNull, isA<AuthFailure>());
      await reported;
      // Wiping the credential belongs to the session, not here: this layer only
      // establishes the fact.
      expect(storage.clearCount, 0);
      // The refused request is not repeated.
      expect(adapter.requests, hasLength(1));
    });
  });

  group('a renewal that could not reach the backend', () {
    test('preserves the credential and answers a retryable failure', () async {
      build([const _Reply(401, {'message': 'Unauthorized'})]);
      authRepository.loginResult = loginUnreachable;

      final result = await repository.current();

      // Not an AuthFailure: nothing was learnt about the credential, so this
      // must never reach the re-enrollment path.
      expect(result.failureOrNull, isA<NetworkFailure>());
      expect(storage.credentials, testCredentials);
      expect(storage.clearCount, 0);
      expect(adapter.requests, hasLength(1));
    });

    test('a storage failure during the renewal is preserved as such', () async {
      build([const _Reply(401, {'message': 'Unauthorized'})]);
      storage.failOnRead = true;

      expect((await repository.current()).failureOrNull, isA<StorageFailure>());
      expect(authRepository.loginCount, 0);
    });
  });
}
