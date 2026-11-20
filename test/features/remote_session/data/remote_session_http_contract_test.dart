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
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/remote_session/data/datasources/remote_session_remote_data_source.dart';
import 'package:remote_control_device/features/remote_session/data/repositories/remote_session_repository_impl.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_ended_by.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_device/features/remote_session/domain/repositories/remote_session_repository.dart';

import '../../../fakes/device_fakes.dart';
import '../../../fakes/remote_session_fakes.dart';
import '../../../fakes/support_fakes.dart';

/// One scripted HTTP reply.
/// A [_Reply] status meaning "no answer within the receive timeout".
const int _timeout = -1;

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
    if (reply.statusCode == _timeout) {
      // The request went out and no answer came back in time: from here it is
      // impossible to tell whether the backend closed the session.
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.receiveTimeout,
      );
    }
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

void main() {
  const config = AppConfig(backendBaseUrl: 'http://backend.test:3000');

  late _RecordingAdapter adapter;
  late InMemoryDeviceTokenStore tokenStore;
  late FakeDeviceCredentialsStorage storage;
  late FakeDeviceAuthRepository authRepository;
  late DeviceCredentialRevocation revocation;
  late RemoteSessionRepository repository;

  void build(List<_Reply> replies) {
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

    repository = RemoteSessionRepositoryImpl(
      remoteDataSource: RemoteSessionRemoteDataSourceImpl(apiClient),
      authenticatedRequest: AuthenticatedDeviceRequest(
        renewDeviceToken: RenewDeviceToken(
          loadDeviceCredentials: LoadDeviceCredentials(storage),
          authenticateDevice: AuthenticateDevice(authRepository),
        ),
        revocation: revocation,
      ),
    );
  }

  tearDown(() async => revocation.dispose());

  /// The backend derives the device from the Device JWT and the session from
  /// the path. A `deviceId` or a `supportRequestId` anywhere on the wire would
  /// be both useless and a lie about where authority comes from.
  void expectNoOwnershipClaimOnTheWire(RequestOptions request) {
    expect(request.queryParameters, isEmpty);
    expect(request.data, isNull);
    expect(request.path, isNot(contains(testDeviceId)));
    expect(request.path, isNot(contains(testPublicId)));
    expect(request.path, isNot(contains(testSupportRequestId)));
  }

  group('GET /device/remote-sessions/current', () {
    test('reads the documented path, envelope and technician block', () async {
      build([
        _Reply(200, currentRemoteSessionEnvelope(remoteSessionJson())),
      ]);

      final result = await repository.current();

      expect(adapter.lastRequest.method, 'GET');
      expect(adapter.lastRequest.path, '/device/remote-sessions/current');
      expect(
        adapter.lastRequest.headers['Authorization'],
        'Bearer $testDeviceJwt',
      );
      expectNoOwnershipClaimOnTheWire(adapter.lastRequest);

      final session = result.valueOrNull;
      expect(session?.id, testRemoteSessionId);
      expect(session?.supportRequestId, testSupportRequestId);
      expect(session?.status, RemoteSessionStatus.connecting);
      expect(session?.technician?.id, testTechnicianId);
      expect(session?.technician?.name, testTechnicianName);
    });

    test('is the device prefix, never the technician controller', () {
      expect(RemoteSessionRemoteDataSourceImpl.basePath, '/device/remote-sessions');
      expect(
        RemoteSessionRemoteDataSourceImpl.currentPath,
        '/device/remote-sessions/current',
      );
      expect(
        RemoteSessionRemoteDataSourceImpl.closePath(testRemoteSessionId),
        '/device/remote-sessions/$testRemoteSessionId/close',
      );
    });

    test('a null remoteSession is a value, not a failure', () async {
      build([_Reply(200, currentRemoteSessionEnvelope(null))]);

      final result = await repository.current();

      expect(result, isA<Ok<RemoteSession?>>());
      expect(result.valueOrNull, isNull);
    });

    test('a response without the documented envelope fails loudly', () async {
      // Reading an unexpected body as "no session" is the one misreading that
      // would silently drop a live session off the screen.
      build([const _Reply(200, {'unexpected': true})]);

      expect((await repository.current()).failureOrNull, isA<ServerFailure>());
    });

    test('ACTIVE is read, with the connectedAt the backend wrote', () async {
      build([
        _Reply(
          200,
          currentRemoteSessionEnvelope(
            remoteSessionJson(
              status: 'ACTIVE',
              connectedAt: testConnectedAtWire,
            ),
          ),
        ),
      ]);

      final session = (await repository.current()).valueOrNull;
      expect(session?.status, RemoteSessionStatus.active);
      // Taken from the payload, in UTC, exactly as sent. Nothing here computes
      // an activation instant or adjusts the one it was given.
      expect(session?.connectedAt, DateTime.parse(testConnectedAtWire));
      expect(session?.connectedAt?.isUtc, isTrue);
    });

    test('a CONNECTING session has no connectedAt, and none is invented',
        () async {
      build([
        _Reply(200, currentRemoteSessionEnvelope(remoteSessionJson())),
      ]);

      final session = (await repository.current()).valueOrNull;
      expect(session?.status, RemoteSessionStatus.connecting);
      expect(session?.connectedAt, isNull);
    });

    test('an unreadable connectedAt costs a line, never the session', () async {
      build([
        _Reply(
          200,
          currentRemoteSessionEnvelope(
            remoteSessionJson(status: 'ACTIVE', connectedAt: 'yesterday'),
          ),
        ),
      ]);

      final session = (await repository.current()).valueOrNull;
      expect(session, isNotNull);
      expect(session?.status, RemoteSessionStatus.active);
      expect(session?.connectedAt, isNull);
    });

    test('an unknown future status is named, never guessed at', () async {
      build([
        _Reply(
          200,
          currentRemoteSessionEnvelope(remoteSessionJson(status: 'PAUSED')),
        ),
      ]);

      final status = (await repository.current()).valueOrNull?.status;
      expect(status, RemoteSessionStatus.unknown);
      // And an uninterpretable status is never treated as a live session.
      expect(status?.isLive, isFalse);
    });

    test('a missing technician block costs a name and nothing more', () async {
      build([
        _Reply(
          200,
          currentRemoteSessionEnvelope(
            remoteSessionJson(withTechnician: false),
          ),
        ),
      ]);

      final session = (await repository.current()).valueOrNull;
      expect(session, isNotNull);
      expect(session?.status, RemoteSessionStatus.connecting);
      expect(session?.technician, isNull);
    });

    test('maps 401 that survives a renewal to AuthFailure', () async {
      build([const _Reply(401, {'message': 'Unauthorized'})]);

      expect((await repository.current()).failureOrNull, isA<AuthFailure>());
    });
  });

  group('POST /device/remote-sessions/:id/close', () {
    test('addresses the id from the backend and sends no body', () async {
      build([
        _Reply(200, remoteSessionJson(status: 'CLOSED', endedBy: 'DEVICE')),
      ]);

      final result = await repository.close(testRemoteSessionId);

      expect(adapter.lastRequest.method, 'POST');
      expect(
        adapter.lastRequest.path,
        '/device/remote-sessions/$testRemoteSessionId/close',
      );
      expect(
        adapter.lastRequest.headers['Authorization'],
        'Bearer $testDeviceJwt',
      );
      expectNoOwnershipClaimOnTheWire(adapter.lastRequest);
      // The closed session comes back here, which is exactly why the backend
      // emits no remote-session:closed for a device-initiated close.
      expect(result.valueOrNull?.status, RemoteSessionStatus.closed);
      expect(result.valueOrNull?.status.isLive, isFalse);
    });

    test('maps 404 — unknown, or another device, even CLOSED — to '
        'NotFoundFailure', () async {
      build([const _Reply(404, {'message': 'not found'})]);

      expect(
        (await repository.close(testRemoteSessionId)).failureOrNull,
        isA<NotFoundFailure>(),
      );
    });

    test('maps 409 — a live session whose request cannot complete — to '
        'ConflictFailure', () async {
      // Since remote_control_backend f5b8a1c, the only 409 of this endpoint.
      // An already-CLOSED session of this device is a 200, not a 409.
      build([const _Reply(409, {'message': 'conflict'})]);

      expect(
        (await repository.close(testRemoteSessionId)).failureOrNull,
        isA<ConflictFailure>(),
      );
    });

    test('reads the closed session: endedAt and endedBy as the backend sent '
        'them', () async {
      build([
        _Reply(200, remoteSessionJson(status: 'CLOSED', endedBy: 'DEVICE')),
      ]);

      final session = (await repository.close(testRemoteSessionId)).valueOrNull;

      expect(session?.id, testRemoteSessionId);
      expect(session?.endedAt, DateTime.parse(testEndedAtWire));
      expect(session?.endedAt?.isUtc, isTrue);
      expect(session?.endedBy, RemoteSessionEndedBy.device);
      expect(session?.confirmsCloseOf(testRemoteSessionId), isTrue);
    });

    for (final (wire, endedBy) in [
      ('DEVICE', RemoteSessionEndedBy.device),
      ('TECHNICIAN', RemoteSessionEndedBy.technician),
      ('SYSTEM', RemoteSessionEndedBy.system),
    ]) {
      test('a repeat answers 200 with the original close — endedBy $wire — '
          'and it confirms', () async {
        // Idempotent close: the same body as the first close, whoever made
        // it. Two calls, two identical answers.
        build([
          _Reply(200, remoteSessionJson(status: 'CLOSED', endedBy: wire)),
        ]);

        final first = (await repository.close(testRemoteSessionId)).valueOrNull;
        final repeat =
            (await repository.close(testRemoteSessionId)).valueOrNull;

        expect(adapter.requests, hasLength(2));
        expect(repeat, first);
        expect(repeat?.endedBy, endedBy);
        expect(repeat?.endedAt, DateTime.parse(testEndedAtWire));
        expect(repeat?.confirmsCloseOf(testRemoteSessionId), isTrue);
      });
    }

    test('an endedBy this build does not know is read as unknown, and still '
        'confirms', () async {
      build([
        _Reply(200, remoteSessionJson(status: 'CLOSED', endedBy: 'JANITOR')),
      ]);

      final session = (await repository.close(testRemoteSessionId)).valueOrNull;

      expect(session?.endedBy, RemoteSessionEndedBy.unknown);
      expect(session?.confirmsCloseOf(testRemoteSessionId), isTrue);
    });

    test('a 200 without endedAt parses, but does not confirm', () async {
      build([
        _Reply(
          200,
          remoteSessionJson(status: 'CLOSED', endedBy: 'DEVICE')
            ..['endedAt'] = null,
        ),
      ]);

      final session = (await repository.close(testRemoteSessionId)).valueOrNull;

      expect(session, isNotNull);
      expect(session?.endedAt, isNull);
      expect(session?.confirmsCloseOf(testRemoteSessionId), isFalse);
    });

    test('a 200 naming another session, or still ACTIVE, does not '
        'confirm', () async {
      build([
        _Reply(
          200,
          remoteSessionJson(
            id: testOtherRemoteSessionId,
            status: 'CLOSED',
            endedBy: 'DEVICE',
          ),
        ),
        _Reply(200, remoteSessionJson(status: 'ACTIVE')),
      ]);

      final other = (await repository.close(testRemoteSessionId)).valueOrNull;
      final active = (await repository.close(testRemoteSessionId)).valueOrNull;

      expect(other?.confirmsCloseOf(testRemoteSessionId), isFalse);
      expect(active?.confirmsCloseOf(testRemoteSessionId), isFalse);
    });

    test('maps 500 — nothing written, retrying is safe — to '
        'ServerFailure', () async {
      build([const _Reply(500, {'message': 'Internal server error'})]);

      expect(
        (await repository.close(testRemoteSessionId)).failureOrNull,
        isA<ServerFailure>(),
      );
    });

    test('maps a timeout — the outcome is unknown — to NetworkFailure', () async {
      build([const _Reply(_timeout, {})]);

      expect(
        (await repository.close(testRemoteSessionId)).failureOrNull,
        isA<NetworkFailure>(),
      );
      // Not mistaken for a revoked credential.
      expect(storage.clearCount, 0);
    });

    test('maps 400 — the id was not a UUID — to ValidationFailure', () async {
      build([const _Reply(400, {'message': 'bad request'})]);

      expect(
        (await repository.close(testRemoteSessionId)).failureOrNull,
        isA<ValidationFailure>(),
      );
    });
  });

  group('an expired Device JWT', () {
    test('is renewed once and the call is repeated with the new token', () async {
      build([
        const _Reply(401, {'message': 'Unauthorized'}),
        _Reply(200, currentRemoteSessionEnvelope(remoteSessionJson())),
      ]);

      final result = await repository.current();

      expect(result.valueOrNull?.status, RemoteSessionStatus.connecting);
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

      final result = await repository.close(testRemoteSessionId);

      expect(result.failureOrNull, isA<AuthFailure>());
      expect(authRepository.loginCount, 1);
      expect(adapter.requests, hasLength(2));
    });
  });

  group('a revoked permanent credential', () {
    test('is reported once, and surfaces as the confirmed rejection', () async {
      build([const _Reply(401, {'message': 'Unauthorized'})]);
      authRepository.loginResult = loginRejected;

      final reported = expectLater(revocation.revocations, emits(isNull));
      final result = await repository.close(testRemoteSessionId);

      expect(result.failureOrNull, isA<CredentialRejectedFailure>());
      await reported;
      // Nothing is wiped, here or anywhere: this layer only establishes the
      // fact, and the session withdraws authorisation while keeping the
      // credential.
      expect(storage.clearCount, 0);
      expect(storage.credentials, testCredentials);
      // The refused request is not repeated.
      expect(adapter.requests, hasLength(1));
    });

    test('a renewal answered 401 without the code is not a rejection', () async {
      build([const _Reply(401, {'message': 'Unauthorized'})]);
      // What a private dev tunnel answers the renewal login.
      authRepository.loginResult = loginUnauthorized;

      var reports = 0;
      final subscription = revocation.revocations.listen((_) => reports++);
      final result = await repository.close(testRemoteSessionId);

      expect(result.failureOrNull, isA<AuthFailure>());
      await Future<void>.delayed(Duration.zero);
      expect(reports, 0);
      await subscription.cancel();
      // Nothing is wiped, here or anywhere: this layer only establishes the
      // fact, and the session withdraws authorisation while keeping the
      // credential.
      expect(storage.clearCount, 0);
      expect(storage.credentials, testCredentials);
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
  });
}
