import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/domain/entities/device_realtime_confirmation.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
import 'package:remote_control_device/features/device/domain/realtime/heartbeat_watchdog.dart';
import 'package:remote_control_device/features/device/domain/realtime/realtime_heartbeat_policy.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';

import '../../../fakes/device_fakes.dart';
import '../../../fakes/manual_timers.dart';
import '../../../fakes/realtime_fakes.dart';

const RealtimeHeartbeatPolicy policy1010 = RealtimeHeartbeatPolicy(
  pingInterval: Duration(seconds: 10),
  pingTimeout: Duration(seconds: 10),
);

Duration ms(int value) => Duration(milliseconds: value);
Duration s(int value) => Duration(seconds: value);

/// The realtime bloc's side of the watchdog: what each heartbeat fact does to
/// the channel state, with the socket faked and every deadline on a manual
/// clock.
void main() {
  late FakeDeviceRealtimeClient client;
  late DeviceTokenStore tokenStore;
  late ManualTimers timers;
  late HeartbeatWatchdog watchdog;
  late DeviceRealtimeBloc bloc;
  late List<DeviceRealtimeState> states;

  const confirmation = DeviceRealtimeConfirmation(
    deviceId: testDeviceId,
    publicId: testPublicId,
  );

  setUp(() async {
    timers = ManualTimers();
    client = FakeDeviceRealtimeClient();
    final storage = FakeDeviceCredentialsStorage(testCredentials);
    tokenStore = InMemoryDeviceTokenStore()..save(testDeviceJwt);
    final authRepository = FakeDeviceAuthRepository(
      loginResult: const Ok(testRenewedSession),
      tokenStore: tokenStore,
    );
    watchdog = HeartbeatWatchdog(
      timerFactory: timers.factory,
      monotonicClock: () => timers.now,
      wallClock: () => DateTime.utc(2026, 11, 26).add(timers.now),
    );
    bloc = DeviceRealtimeBloc(
      client: client,
      tokenStore: tokenStore,
      renewDeviceToken: RenewDeviceToken(
        loadDeviceCredentials: LoadDeviceCredentials(storage),
        authenticateDevice: AuthenticateDevice(authRepository),
      ),
      timerFactory: timers.factory,
      clock: () => DateTime.utc(2026, 11, 26).add(timers.now),
      heartbeatWatchdog: watchdog,
    );
    states = [];
    bloc.stream.listen(states.add);
    bloc.add(const DeviceRealtimeStartRequested());
    await pumpEventQueue();
  });

  tearDown(() => bloc.close());

  Future<void> elapse(Duration duration) async {
    timers.elapse(duration);
    await pumpEventQueue();
  }

  Future<void> connect() async {
    await client.emit(const RealtimeConnected(heartbeat: policy1010));
    await client.emit(const RealtimeIdentityConfirmed(confirmation));
    await pumpEventQueue();
    expect(bloc.state, const DeviceRealtimeConnected(confirmation: confirmation));
  }

  Future<void> ping() async {
    await client.emit(const RealtimeHeartbeat());
    await pumpEventQueue();
  }

  test('2. a PING every 10 s keeps the channel connected', () async {
    await connect();
    states.clear();
    for (var i = 0; i < 30; i++) {
      await elapse(ms(10300));
      await ping();
    }
    expect(states, isEmpty);
    expect(client.connectedWithTokens, hasLength(1));
  });

  test('4-5. no PING for 13 s: heartbeat overdue, the confirmation kept, the '
      'socket left to the transport', () async {
    await connect();
    await elapse(ms(12999));
    expect(bloc.state, isA<DeviceRealtimeConnected>());
    await elapse(ms(1));
    expect(
      bloc.state,
      const DeviceRealtimeHeartbeatOverdue(confirmation: confirmation),
    );
    expect(client.disconnectCount, 0, reason: 'nothing closed for a suspicion');
    expect(client.connectedWithTokens, hasLength(1));
  });

  test('a PING after the overdue brings the same connection back', () async {
    await connect();
    await elapse(s(15));
    expect(bloc.state, isA<DeviceRealtimeHeartbeatOverdue>());
    await ping();
    expect(bloc.state, const DeviceRealtimeConnected(confirmation: confirmation));
    expect(client.connectedWithTokens, hasLength(1));
  });

  test('the transport gives up after the overdue: reconnecting, as always',
      () async {
    await connect();
    await elapse(s(14));
    await client.emit(const RealtimeDisconnected());
    await pumpEventQueue();
    expect(bloc.state, const DeviceRealtimeReconnecting());
    // Nothing of the old watch is left: no stall, no new socket from it.
    await elapse(s(60));
    expect(bloc.state, const DeviceRealtimeReconnecting());
    expect(client.connectedWithTokens, hasLength(1));
  });

  test('the transport never gives up: at 25 s a new socket replaces it, with '
      'the same token, and is watched afresh', () async {
    await connect();
    await elapse(s(25) - ms(1));
    expect(bloc.state, isA<DeviceRealtimeHeartbeatOverdue>());
    expect(client.connectedWithTokens, hasLength(1));
    await elapse(ms(1));
    expect(bloc.state, const DeviceRealtimeReconnecting());
    expect(client.connectedWithTokens, [testDeviceJwt, testDeviceJwt]);

    await client.emit(const RealtimeConnected(heartbeat: policy1010));
    await pumpEventQueue();
    expect(bloc.state, const DeviceRealtimeConnected());
    await elapse(ms(12999));
    expect(bloc.state, const DeviceRealtimeConnected());
    await elapse(ms(1));
    expect(bloc.state, isA<DeviceRealtimeHeartbeatOverdue>());
  });

  test('6-7. a reconnection while the old deadline is pending: the new '
      'connection counts from its own start', () async {
    await connect();
    await elapse(s(9));
    await client.emit(const RealtimeDisconnected());
    await client.emit(const RealtimeConnected(heartbeat: policy1010));
    await pumpEventQueue();
    // The old connection's 13 s pass: nothing.
    await elapse(s(5));
    expect(bloc.state, const DeviceRealtimeConnected());
    await elapse(s(8) - ms(1));
    expect(bloc.state, const DeviceRealtimeConnected());
    await elapse(ms(1));
    expect(bloc.state, isA<DeviceRealtimeHeartbeatOverdue>());
  });

  test('a PING while not connected changes nothing', () async {
    await ping(); // before the namespace accepted the connection
    expect(bloc.state, const DeviceRealtimeConnecting());
    await connect();
    await client.emit(const RealtimeDisconnected());
    await pumpEventQueue();
    await ping(); // after the loss
    expect(bloc.state, const DeviceRealtimeReconnecting());
    await elapse(s(60));
    expect(bloc.state, const DeviceRealtimeReconnecting());
  });

  test('a stop ends the watch: nothing is raised for it afterwards', () async {
    await connect();
    bloc.add(const DeviceRealtimeStopRequested());
    await pumpEventQueue();
    await elapse(s(60));
    expect(bloc.state, const DeviceRealtimeDisconnected());
    expect(watchdog.confirmFresh(), isFalse);
  });

  test('a handshake without the values: not watched, as before the watchdog',
      () async {
    await client.emit(const RealtimeConnected());
    await pumpEventQueue();
    await elapse(s(120));
    expect(bloc.state, const DeviceRealtimeConnected());
    expect(watchdog.confirmFresh(), isTrue);
  });

  test('an overdue raised just before a PING: suspended, then back, in that '
      'order', () async {
    await connect();
    await elapse(ms(12999));
    states.clear();
    timers.fireNext(); // the deadline check: one more turn
    timers.fireNext(); // the extra turn: overdue raised, not yet handled
    await client.emit(const RealtimeHeartbeat());
    await pumpEventQueue();
    expect(states, const [
      DeviceRealtimeHeartbeatOverdue(confirmation: confirmation),
      DeviceRealtimeConnected(confirmation: confirmation),
    ]);
  });
}
