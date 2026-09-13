import 'dart:async';

import 'package:remote_control_device/features/device/domain/realtime/device_realtime_client.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';

/// Stand-in for the Socket.IO client.
///
/// It exists so the blocs can be exercised without a socket, a backend or a
/// timer: tests decide exactly which signal arrives and when, and can assert
/// which token each handshake would have carried.
class FakeDeviceRealtimeClient implements DeviceRealtimeClient {
  final StreamController<DeviceRealtimeSignal> _signals =
      StreamController<DeviceRealtimeSignal>.broadcast();

  /// One entry per connection attempt, in order. The last one is the token the
  /// most recent handshake would have presented.
  final List<String> connectedWithTokens = [];

  int disconnectCount = 0;
  int disposeCount = 0;

  @override
  Stream<DeviceRealtimeSignal> get signals => _signals.stream;

  @override
  void connect(String deviceToken) => connectedWithTokens.add(deviceToken);

  @override
  void disconnect() => disconnectCount++;

  @override
  Future<void> dispose() async {
    disposeCount++;
    if (!_signals.isClosed) await _signals.close();
  }

  /// Pushes a signal and lets the listening bloc process it before returning.
  Future<void> emit(DeviceRealtimeSignal signal) async {
    push(signal);
    await pump();
  }

  /// Pushes a signal without waiting. Widget tests need this: their fake-async
  /// zone only advances when the tester pumps, so awaiting a real delay there
  /// would never complete.
  void push(DeviceRealtimeSignal signal) => _signals.add(signal);

  /// Drains the microtask queue so stream delivery and bloc event handling
  /// complete before the next assertion.
  static Future<void> pump() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }
}
