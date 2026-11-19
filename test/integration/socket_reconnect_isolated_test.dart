// The /devices recovery end to end, against the isolated harness in
// tool/realtime_harness (Prompts 34–36).
//
// Real HTTP client, real SocketIoDeviceRealtimeClient (socket_io_client), real
// DeviceSessionBloc + DeviceRealtimeBloc + DeviceRealtimeCoordinator, against
// remote_control_backend's own gateway, middleware, controller and auth service
// with in-memory repositories and fault injection. Fictitious device and
// secret; nothing leaves 127.0.0.1.
//
// Skipped unless REALTIME_HARNESS is set and the harness is running.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/app/device_realtime_coordinator.dart';
import 'package:remote_control_device/core/config/app_config.dart';
import 'package:remote_control_device/core/network/api_client.dart';
import 'package:remote_control_device/core/session/device_credential_revocation.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/data/datasources/device_auth_remote_data_source.dart';
import 'package:remote_control_device/features/device/data/realtime/socket_io_device_realtime_client.dart';
import 'package:remote_control_device/features/device/data/repositories/device_auth_repository_impl.dart';
import 'package:remote_control_device/features/device/domain/entities/device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/check_device_status.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/device/domain/usecases/suspend_device_authorization.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';

import '../fakes/device_fakes.dart';

// The harness's fictitious identity (tool/realtime_harness/isolated_backend.ts).
const _deviceId = '11111111-2222-4333-8444-555555555555';
const _deviceSecret = 'p34-fictitious-secret-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

final _http = HttpClient();

Future<Map<String, dynamic>> _ctl(String path, [Map<String, Object?>? body]) async {
  final req = await _http.post('127.0.0.1', 3102, path);
  req.headers.contentType = ContentType.json;
  req.write(jsonEncode(body ?? {}));
  final res = await req.close();
  return jsonDecode(await res.transform(utf8.decoder).join())
      as Map<String, dynamic>;
}

Future<List<Map<String, dynamic>>> _events() async =>
    ((await _ctl('/log'))['events'] as List).cast<Map<String, dynamic>>();

Future<bool> _online() async => (await _ctl('/log'))['online'] as bool;

List<String> _handshakes(List<Map<String, dynamic>> e) => [
  for (final x in e)
    if (x['ev'] == 'handshake') '${x['token']}:${x['result']}',
];

/// The data.code each refused handshake was answered with, in order.
List<String> _refusalCodes(List<Map<String, dynamic>> e) => [
  for (final x in e)
    if (x['ev'] == 'handshake' && x['code'] != null) '${x['code']}',
];

List<String> _logins(List<Map<String, dynamic>> e) => [
  for (final x in e)
    if (x['ev'] == 'login')
      '${x['result']}${x['code'] != null ? ' ${x['code']}' : ''}',
];

List<String> _protectedCalls(List<Map<String, dynamic>> e) => [
  for (final x in e)
    if (x['ev'] == 'http' && x['path'] != '/device-auth/login')
      '${x['method']} ${x['path']}',
];

/// The production graph for authentication + realtime, as AppDependencies and
/// RemoteControlApp wire it, with short timings.
class _Rig {
  _Rig() {
    const config = AppConfig(
      backendBaseUrl: 'http://127.0.0.1:3100',
      realtimeConnectTimeout: Duration(seconds: 3),
      realtimeReconnectionDelay: Duration(milliseconds: 300),
      realtimeReconnectionDelayMax: Duration(seconds: 1),
      realtimeReauthRetryDelay: Duration(seconds: 1),
      realtimeRecoveryBackoff: [
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 3),
      ],
      realtimeStableConnectionPeriod: Duration(seconds: 2),
    );
    storage = FakeDeviceCredentialsStorage(
      const DeviceCredentials(deviceId: _deviceId, deviceSecret: _deviceSecret),
    );
    final api = ApiClient(config: config, tokenStore: tokenStore);
    final repo = DeviceAuthRepositoryImpl(
      remoteDataSource: DeviceAuthRemoteDataSourceImpl(api),
      tokenStore: tokenStore,
    );
    final load = LoadDeviceCredentials(storage);
    final authenticate = AuthenticateDevice(repo);
    session = DeviceSessionBloc(
      loadDeviceCredentials: load,
      authenticateDevice: authenticate,
      checkDeviceStatus: CheckDeviceStatus(repo),
      suspendDeviceAuthorization: SuspendDeviceAuthorization(repo),
      retryBackoff: const [Duration(milliseconds: 500)],
    );
    realtime = DeviceRealtimeBloc(
      client: SocketIoDeviceRealtimeClient(config: config),
      tokenStore: tokenStore,
      renewDeviceToken: RenewDeviceToken(
        loadDeviceCredentials: load,
        authenticateDevice: authenticate,
      ),
      reauthRetryDelay: config.realtimeReauthRetryDelay,
      recoveryBackoff: config.realtimeRecoveryBackoff,
      stableConnectionPeriod: config.realtimeStableConnectionPeriod,
    );
    coordinator = DeviceRealtimeCoordinator(
      sessionBloc: session,
      realtimeBloc: realtime,
      credentialRevocation: revocation,
    )..start();
    _subs.add(realtime.stream.listen((s) => realtimeHistory.add(_name(s))));
    _subs.add(
      session.stream.listen(
        (s) => sessionHistory.add(
          s.runtimeType.toString().replaceFirst('DeviceSession', ''),
        ),
      ),
    );
  }

  final tokenStore = InMemoryDeviceTokenStore();
  final revocation = DeviceCredentialRevocation();
  late final FakeDeviceCredentialsStorage storage;
  late final DeviceSessionBloc session;
  late final DeviceRealtimeBloc realtime;
  late final DeviceRealtimeCoordinator coordinator;
  final realtimeHistory = <String>[];
  final sessionHistory = <String>[];
  final _subs = <StreamSubscription<Object?>>[];

  static String _name(DeviceRealtimeState s) => switch (s) {
    DeviceRealtimeDisconnected(:final cause) => 'Disconnected(${cause.name})',
    DeviceRealtimeConnected(:final confirmation) =>
      confirmation == null ? 'Connected' : 'Connected+confirmed',
    _ => s.runtimeType.toString().replaceFirst('DeviceRealtime', ''),
  };

  void start() => session.add(const DeviceSessionStarted());

  int get connections =>
      realtimeHistory.where((s) => s == 'Connected').length;

  Future<void> waitFor(
    bool Function() cond,
    String what, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!cond()) {
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'timeout waiting for $what; '
          'realtime=$realtimeHistory session=$sessionHistory',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> waitConnections(int n, String what) =>
      waitFor(() => connections >= n, what);

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await coordinator.dispose();
    await realtime.close();
    await session.close();
    await revocation.dispose();
  }
}

Future<void> _sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  final harness = Platform.environment['REALTIME_HARNESS'] != null;

  group('isolated /devices harness', skip: harness ? false : 'needs '
      'REALTIME_HARNESS=1 and tool/realtime_harness running', () {
    late _Rig rig;

    setUp(() async {
      await _ctl('/reset');
      rig = _Rig();
    });

    tearDown(() async {
      final e = await _events();
      // ignore: avoid_print
      print(
        '  realtime: ${rig.realtimeHistory}\n'
        '  session:  ${rig.sessionHistory}\n'
        '  logins:   ${_logins(e)}\n'
        '  handshakes: ${_handshakes(e)}\n'
        '  protected: ${_protectedCalls(e)}',
      );
      await rig.dispose();
    });

    test('A. normal connection: login, check-status, socket, ONLINE', () async {
      rig.start();
      await rig.waitFor(
        () => rig.realtimeHistory.contains('Connected+confirmed'),
        'device:connected',
      );
      expect(rig.session.state, isA<DeviceSessionReady>());
      expect(await _online(), isTrue);
      final e = await _events();
      expect(_logins(e), ['200']);
      expect(_handshakes(e), ['tok#1:accepted']);
    });

    test('B. JWT expired before a reconnection handshake', () async {
      await _ctl('/ctl', {'tokenTtlSeconds': 2});
      rig.start();
      await rig.waitConnections(1, 'first connection');
      await _ctl('/ctl', {'tokenTtlSeconds': null});
      await _sleep(2600);
      await _ctl('/ctl', {'cutMs': 200});
      await rig.waitConnections(2, 'reconnected after renewal');
      final e = await _events();
      expect(_logins(e), ['200', '200']);
      final hs = _handshakes(e);
      expect(hs.first, 'tok#1:accepted');
      expect(hs.last, 'tok#2:accepted');
      expect(await _online(), isTrue);
    });

    test('C. the JWT of the login is refused, and so is the renewed one: '
        'recovered on the backoff once the backend is healthy', () async {
      await _ctl('/ctl', {'rejectHandshakes': 1000});
      rig.start();
      // Several rejections, spaced by the backoff, never a stop.
      await _sleep(4500);
      var e = await _events();
      expect(_handshakes(e).length, greaterThanOrEqualTo(3));
      expect(rig.realtime.state, isNot(isA<DeviceRealtimeDisconnected>()));
      expect(rig.session.state, isA<DeviceSessionReady>());
      await _ctl('/ctl', {'rejectHandshakes': 0});
      await rig.waitConnections(1, 'recovered without a restart');
      e = await _events();
      expect(_handshakes(e).last, endsWith(':accepted'));
      expect(rig.storage.clearCount, 0);
      expect(await _online(), isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('D1. one transient rejection recovers at once', () async {
      await _ctl('/ctl', {'rejectHandshakes': 1});
      rig.start();
      await rig.waitConnections(1, 'connected');
      final e = await _events();
      expect(_handshakes(e), ['tok#1:rejected (injected)', 'tok#2:accepted']);
    });

    test('D2. two transient rejections: online again without a restart',
        () async {
      rig.start();
      await rig.waitConnections(1, 'first connection');
      await _ctl('/ctl', {'rejectHandshakes': 2, 'cutMs': 100});
      await rig.waitConnections(2, 'recovered');
      final e = await _events();
      expect(_handshakes(e), [
        'tok#1:accepted',
        'tok#1:rejected (injected)',
        'tok#2:rejected (injected)',
        'tok#3:accepted',
      ]);
      expect(await _online(), isTrue);
      expect(rig.session.state, isA<DeviceSessionReady>());
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('E1. a PostgreSQL error in two handshakes is DEVICE_AUTH_UNAVAILABLE: '
        'no login, the same JWT is presented again and accepted', () async {
      rig.start();
      await rig.waitConnections(1, 'first connection');
      await _ctl('/ctl', {'dbFailHandshakes': 2, 'cutMs': 100});
      await rig.waitConnections(2, 'recovered');
      final e = await _events();
      expect(_handshakes(e), [
        'tok#1:accepted',
        startsWith('tok#1:rejected (QueryFailedError'),
        startsWith('tok#1:rejected (QueryFailedError'),
        'tok#1:accepted',
      ]);
      expect(_refusalCodes(e), [
        'DEVICE_AUTH_UNAVAILABLE',
        'DEVICE_AUTH_UNAVAILABLE',
      ]);
      expect(_logins(e), ['200'], reason: 'no renewal for an unavailable check');
      expect(rig.session.state, isA<DeviceSessionReady>());
      expect(rig.tokenStore.token, isNotNull);
      expect(rig.storage.clearCount, 0);
      expect(await _online(), isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('E2. PostgreSQL down for a while: never Connected, no login, and the '
        'same JWT reconnects once it is back', () async {
      rig.start();
      await rig.waitConnections(1, 'first connection');
      await _ctl('/ctl', {'dbDown': true, 'cutMs': 100});
      await _sleep(4000);
      expect(rig.realtime.state, isNot(isA<DeviceRealtimeConnected>()));
      expect(await _online(), isFalse);
      expect(rig.session.state, isA<DeviceSessionReady>());
      await _ctl('/ctl', {'dbDown': false});
      await rig.waitConnections(2, 'recovered');
      final e = await _events();
      expect(_logins(e), ['200']);
      expect(_refusalCodes(e), isNotEmpty);
      expect(_refusalCodes(e).toSet(), {'DEVICE_AUTH_UNAVAILABLE'});
      expect(_handshakes(e).every((h) => h.startsWith('tok#1:')), isTrue);
      expect(rig.storage.clearCount, 0);
      expect(await _online(), isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('E3. UNAVAILABLE on the very first handshakes: the JWT of the startup '
        'login is kept and accepted later', () async {
      await _ctl('/ctl', {'dbFailHandshakes': 2});
      rig.start();
      await rig.waitConnections(1, 'connected');
      final e = await _events();
      expect(_logins(e), ['200']);
      expect(_refusalCodes(e), [
        'DEVICE_AUTH_UNAVAILABLE',
        'DEVICE_AUTH_UNAVAILABLE',
      ]);
      expect(_handshakes(e).last, 'tok#1:accepted');
      // Spaced by the backoff (1 s, then 2 s), never at once.
      final times = [
        for (final x in e)
          if (x['ev'] == 'handshake') x['t'] as int,
      ];
      expect(times[1] - times[0], greaterThanOrEqualTo(900));
      expect(times[2] - times[1], greaterThanOrEqualTo(1900));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('E4. the JWT expires while the database is down: the attempt after '
        'expiry is DEVICE_AUTH_UNAUTHORIZED, renewed once the login works',
        () async {
      await _ctl('/ctl', {'tokenTtlSeconds': 3});
      rig.start();
      await rig.waitConnections(1, 'first connection');
      await _ctl('/ctl', {'tokenTtlSeconds': null, 'dbDown': true, 'cutMs': 100});
      await _sleep(6000); // tok#1 expires during the backoff
      var e = await _events();
      expect(_refusalCodes(e), contains('DEVICE_AUTH_UNAUTHORIZED'));
      expect(_logins(e), contains('500'), reason: 'renewal tried, db down');
      expect(rig.realtime.state, isNot(isA<DeviceRealtimeConnected>()));
      await _ctl('/ctl', {'dbDown': false});
      await rig.waitConnections(2, 'recovered');
      e = await _events();
      expect(_logins(e).last, '200');
      expect(_handshakes(e).last, 'tok#2:accepted');
      // Not trapped on the expired token: once refused it is never presented
      // again.
      final hs = _handshakes(e);
      final firstRefusal = hs.indexWhere(
        (h) => h.startsWith('tok#1:rejected (UnauthorizedException'),
      );
      expect(firstRefusal, isNonNegative);
      expect(
        hs.skip(firstRefusal + 1).where((h) => h.startsWith('tok#1:')),
        isEmpty,
      );
      expect(rig.storage.clearCount, 0);
      expect(await _online(), isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('E5. UNAVAILABLE then UNAUTHORIZED: one renewal, then connected',
        () async {
      rig.start();
      await rig.waitConnections(1, 'first connection');
      await _ctl('/ctl', {'dbFailHandshakes': 1, 'cutMs': 100});
      // The UNAVAILABLE retry waits 1 s; arm the refusal for that attempt.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!_refusalCodes(await _events()).contains('DEVICE_AUTH_UNAVAILABLE')) {
        if (DateTime.now().isAfter(deadline)) fail('no UNAVAILABLE refusal');
        await _sleep(50);
      }
      await _ctl('/ctl', {'rejectHandshakes': 1});
      await rig.waitConnections(2, 'recovered');
      final e = await _events();
      expect(_refusalCodes(e), [
        'DEVICE_AUTH_UNAVAILABLE',
        'DEVICE_AUTH_UNAUTHORIZED',
      ]);
      expect(_logins(e), ['200', '200']);
      expect(_handshakes(e).last, 'tok#2:accepted');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('F1. deactivation (admin PATCH, io server disconnect): '
        'CredentialRefused, no loop; reactivation + explicit retry recovers',
        () async {
      rig.start();
      await rig.waitConnections(1, 'first connection');
      await _ctl('/ctl', {'setActive': false});
      await rig.waitFor(
        () => rig.session.state is DeviceSessionCredentialRefused,
        'CredentialRefused',
      );
      expect(rig.tokenStore.token, isNull);
      await _sleep(8000);
      var e = await _events();
      expect(_logins(e), ['200', '401 DEVICE_CREDENTIAL_REJECTED'],
          reason: 'one renewal discovers it, then nothing automatic');
      expect(_handshakes(e).length, 1);
      expect(_protectedCalls(e), ['GET /device-auth/check-status'],
          reason: 'only the startup check-status');
      expect(rig.storage.clearCount, 0);

      await _ctl('/ctl', {'setActive': true});
      rig.session.add(const DeviceSessionRetryRequested());
      await rig.waitConnections(2, 'recovered after reactivation');
      e = await _events();
      expect(_logins(e).last, '200');
      expect(await _online(), isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('F2. deactivated while the transport was down: refusal confirmed',
        () async {
      rig.start();
      await rig.waitConnections(1, 'first connection');
      await _ctl('/ctl', {'cutMs': 1500});
      await _ctl('/ctl', {'setActive': false});
      await rig.waitFor(
        () => rig.session.state is DeviceSessionCredentialRefused,
        'CredentialRefused',
      );
      await _sleep(4000);
      final e = await _events();
      expect(_logins(e), ['200', '401 DEVICE_CREDENTIAL_REJECTED']);
      expect(rig.realtime.state, isA<DeviceRealtimeDisconnected>());
      expect(rig.tokenStore.token, isNull);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('G1. connectivity loss: the package reconnects with the same token',
        () async {
      rig.start();
      await rig.waitConnections(1, 'first connection');
      await _ctl('/ctl', {'cutMs': 3000});
      await rig.waitFor(
        () => rig.realtime.state is DeviceRealtimeReconnecting,
        'reconnecting',
      );
      expect(await _online(), isFalse);
      await rig.waitConnections(2, 'reconnected');
      final e = await _events();
      expect(_handshakes(e), ['tok#1:accepted', 'tok#1:accepted']);
      expect(_logins(e), ['200']);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('G2. server-initiated disconnect of an active device: re-authenticates '
        'and reconnects, and the stray close error is absorbed', () async {
      rig.start();
      await rig.waitConnections(1, 'first connection');
      await _ctl('/ctl', {'serverDisconnect': true});
      await rig.waitConnections(2, 'reconnected');
      final e = await _events();
      expect(_logins(e), ['200', '200']);
      expect(_handshakes(e), ['tok#1:accepted', 'tok#2:accepted']);
      expect(await _online(), isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
