import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';

/// Port to the realtime channel of the backend (`/devices`).
///
/// The Socket.IO package lives behind this interface and nowhere else, so
/// domain and presentation never import `package:socket_io_client`.
abstract interface class DeviceRealtimeClient {
  /// Everything the connection has to say. Broadcast: late subscribers are
  /// allowed, and a signal emitted with no listener is simply dropped.
  Stream<DeviceRealtimeSignal> get signals;

  /// Opens a connection authenticated with [deviceToken].
  ///
  /// Any previous connection is released first, so a token that has been
  /// replaced can never survive inside a cached transport object.
  void connect(String deviceToken);

  /// Closes and releases the current connection. Intentional: no reconnection
  /// follows, and no [RealtimeDisconnected] signal is emitted for it.
  void disconnect();

  /// Releases the connection and closes [signals]. The client is unusable
  /// afterwards.
  Future<void> dispose();
}
