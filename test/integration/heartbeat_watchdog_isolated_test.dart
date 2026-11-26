// The heartbeat watchdog against the real Engine.IO heartbeat (Prompt 42).
//
// Real SocketIoDeviceRealtimeClient (socket_io_client 3.1.6) + real
// DeviceRealtimeBloc + real HeartbeatWatchdog on the system clocks, against a
// real socket.io 4.8.1 server (tool/realtime_harness/heartbeat_server.js,
// pingInterval 2 s / pingTimeout 5 s) behind the half-open relay
// (tool/realtime_harness/half_open_relay.js). What it proves that the fakes
// cannot: that the package really reports the handshake values and every
// PING, and when its own `ping timeout` fires compared with the watchdog.
//
// With 2 s / 5 s: the watchdog's limit is 2 + 3 = 5 s after the last PING;
// the package gives up 2 + 5 = 7 s after it.
//
// Skipped unless HEARTBEAT_HARNESS is set and both processes are running:
//
//   NODE_PATH=<scratch>/node_modules node tool/realtime_harness/heartbeat_server.js
//   RELAY_PORT=3121 UPSTREAM_PORT=3120 CTL_PORT=3122 \
//     node tool/realtime_harness/half_open_relay.js
//   HEARTBEAT_HARNESS=1 flutter test test/integration/heartbeat_watchdog_isolated_test.dart
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/config/app_config.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/data/realtime/socket_io_device_realtime_client.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
import 'package:remote_control_device/features/device/domain/realtime/heartbeat_watchdog.dart';
import 'package:remote_control_device/features/device/domain/realtime/realtime_heartbeat_policy.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';

import '../fakes/device_fakes.dart';

final _http = HttpClient();

Future<void> _relay(Map<String, Object?> command) async {
  final req = await _http.post('127.0.0.1', 3122, '/ctl');
  req.headers.contentType = ContentType.json;
  req.write(jsonEncode(command));
  final res = await req.close();
  await res.drain<void>();
}

/// Waits until [predicate] holds, polling every 10 ms, up to [timeout].
Future<void> _until(bool Function() predicate, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  final harness = Platform.environment['HEARTBEAT_HARNESS'] != null;

  group(
    'real Engine.IO heartbeat',
    skip: harness
        ? false
        : 'needs HEARTBEAT_HARNESS=1, heartbeat_server.js and '
              'half_open_relay.js running',
    () {
      late SocketIoDeviceRealtimeClient client;
      late DeviceRealtimeBloc bloc;
      late List<(DateTime, DeviceRealtimeSignal)> signals;
      late List<(DateTime, DeviceRealtimeState)> states;
      late StreamSubscription<DeviceRealtimeSignal> signalSubscription;

      setUp(() async {
        await _relay({'unblock': true});
        client = SocketIoDeviceRealtimeClient(
          config: const AppConfig(
            backendBaseUrl: 'http://127.0.0.1:3121',
            realtimeReconnectionDelay: Duration(milliseconds: 300),
            realtimeReconnectionDelayMax: Duration(seconds: 1),
          ),
        );
        final tokenStore = InMemoryDeviceTokenStore()..save(testDeviceJwt);
        final storage = FakeDeviceCredentialsStorage(testCredentials);
        final auth = FakeDeviceAuthRepository(tokenStore: tokenStore);
        bloc = DeviceRealtimeBloc(
          client: client,
          tokenStore: tokenStore,
          renewDeviceToken: RenewDeviceToken(
            loadDeviceCredentials: LoadDeviceCredentials(storage),
            authenticateDevice: AuthenticateDevice(auth),
          ),
          heartbeatWatchdog: HeartbeatWatchdog(),
        );
        signals = [];
        states = [];
        signalSubscription = client.signals.listen(
          (signal) => signals.add((DateTime.now(), signal)),
        );
        bloc.stream.listen((state) => states.add((DateTime.now(), state)));
        bloc.add(const DeviceRealtimeStartRequested());
        await _until(
          () => bloc.state is DeviceRealtimeConnected,
          const Duration(seconds: 10),
        );
      });

      tearDown(() async {
        await _relay({'unblock': true});
        await signalSubscription.cancel();
        await bloc.close();
      });

      List<DateTime> pingTimes() => [
        for (final (at, signal) in signals)
          if (signal is RealtimeHeartbeat) at,
      ];

      Future<DateTime> nextPing() async {
        final count = pingTimes().length;
        await _until(
          () => pingTimes().length > count,
          const Duration(seconds: 10),
        );
        return pingTimes().last;
      }

      DateTime? firstState<T>({required DateTime after}) {
        for (final (at, state) in states) {
          if (state is T && at.isAfter(after)) return at;
        }
        return null;
      }

      double secondsBetween(DateTime a, DateTime b) =>
          b.difference(a).inMilliseconds / 1000;

      test('the handshake values reach RealtimeConnected and every PING is '
          'reported, about pingInterval apart', () async {
        final connected = signals
            .map((entry) => entry.$2)
            .whereType<RealtimeConnected>()
            .single;
        expect(
          connected.heartbeat,
          const RealtimeHeartbeatPolicy(
            pingInterval: Duration(seconds: 2),
            pingTimeout: Duration(seconds: 5),
          ),
        );
        for (var i = 0; i < 4; i++) {
          await nextPing();
        }
        final times = pingTimes();
        for (var i = 1; i < times.length; i++) {
          final gap = secondsBetween(times[i - 1], times[i]);
          // ignore: avoid_print
          print('PING gap ${gap.toStringAsFixed(3)} s');
          expect(gap, inInclusiveRange(1.9, 2.6));
        }
        expect(bloc.state, isA<DeviceRealtimeConnected>());
      });

      test('half-open (both directions held): overdue 5 s after the last '
          'PING, the package\'s own disconnect at 7 s', () async {
        final lastPing = await nextPing();
        await _relay({'block': 'both', 'ms': 12000});
        await _until(
          () => bloc.state is DeviceRealtimeReconnecting,
          const Duration(seconds: 12),
        );
        final overdue = firstState<DeviceRealtimeHeartbeatOverdue>(
          after: lastPing,
        )!;
        final lost = firstState<DeviceRealtimeReconnecting>(after: lastPing)!;
        // ignore: avoid_print
        print(
          'overdue +${secondsBetween(lastPing, overdue).toStringAsFixed(3)} s, '
          'transport disconnect +${secondsBetween(lastPing, lost).toStringAsFixed(3)} s '
          'after the last PING',
        );
        expect(secondsBetween(lastPing, overdue), inInclusiveRange(4.95, 5.3));
        expect(secondsBetween(lastPing, lost), inInclusiveRange(6.9, 7.5));

        // Back after the block: a new socket, watched afresh.
        await _until(
          () => bloc.state is DeviceRealtimeConnected,
          const Duration(seconds: 15),
        );
      });

      test('a PING held back past the limit and then delivered: overdue, then '
          'connected again on the same socket', () async {
        final lastPing = await nextPing();
        // The next PING leaves ~2 s after the PONG; held until 6 s. The
        // server waits 5 s for its PONG, which is held too and delivered at
        // 6 s, before its own limit.
        await _relay({'block': 'both', 'ms': 6000});
        await _until(
          () =>
              firstState<DeviceRealtimeHeartbeatOverdue>(after: lastPing) !=
              null,
          const Duration(seconds: 8),
        );
        await _until(
          () => pingTimes().last.isAfter(lastPing),
          const Duration(seconds: 8),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(bloc.state, isA<DeviceRealtimeConnected>());
        expect(
          firstState<DeviceRealtimeReconnecting>(after: lastPing),
          isNull,
          reason: 'the socket was never lost',
        );
        expect(
          signals.where((entry) => entry.$2 is RealtimeConnected),
          hasLength(1),
          reason: 'no new connection',
        );
      });

      test('the tablet receives but cannot send: PINGs keep coming until the '
          'server gives up on its PONG; then overdue 5 s after the last one',
          () async {
        final blockedAt = await nextPing();
        await _relay({'block': 'toServer', 'ms': 20000});
        await _until(
          () => bloc.state is DeviceRealtimeReconnecting,
          const Duration(seconds: 20),
        );
        final lost = firstState<DeviceRealtimeReconnecting>(after: blockedAt)!;
        final overdue = firstState<DeviceRealtimeHeartbeatOverdue>(
          after: blockedAt,
        );
        final lastPing = pingTimes().lastWhere((at) => at.isBefore(lost));
        // ignore: avoid_print
        print(
          'one-way: PINGs received after the block '
          '${pingTimes().where((at) => at.isAfter(blockedAt)).length}; last '
          'one +${secondsBetween(blockedAt, lastPing).toStringAsFixed(3)} s; '
          'overdue ${overdue == null ? 'never' : '+${secondsBetween(lastPing, overdue).toStringAsFixed(3)} s'}, '
          'transport disconnect +${secondsBetween(lastPing, lost).toStringAsFixed(3)} s '
          'after the last PING',
        );
        if (overdue != null) {
          expect(secondsBetween(lastPing, overdue), greaterThanOrEqualTo(4.95));
          expect(overdue.isBefore(lost), isTrue);
        } else {
          // Only acceptable if the transport noticed first.
          expect(secondsBetween(lastPing, lost), lessThan(5.0));
        }
      });
    },
  );
}
