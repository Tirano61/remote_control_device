import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:remote_control_device/core/config/app_config.dart';
import 'package:remote_control_device/features/device/data/realtime/device_realtime_payloads.dart';
import 'package:remote_control_device/features/device/data/realtime/device_socket_options.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_client.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';

/// The only place in the application that knows Socket.IO exists.
///
/// It translates the package's callbacks into [DeviceRealtimeSignal]s and keeps
/// every decision about *what they mean* out of here: this class never renews a
/// token, never touches credentials and never decides to give up.
///
/// One socket per token. [connect] always builds a fresh socket rather than
/// re-opening the existing one, because the `auth` map is captured when the
/// socket is created — re-opening would re-present the token it was built with,
/// which is precisely the token that was just refused.
class SocketIoDeviceRealtimeClient implements DeviceRealtimeClient {
  SocketIoDeviceRealtimeClient({required AppConfig config}) : _config = config;

  static const String _loggerName = 'realtime';

  final AppConfig _config;
  final StreamController<DeviceRealtimeSignal> _signals =
      StreamController<DeviceRealtimeSignal>.broadcast();

  io.Socket? _socket;

  /// Removers returned by every registered listener, so teardown is explicit
  /// and not left to the package's own bookkeeping.
  final List<void Function()> _listenerRemovers = [];

  @override
  Stream<DeviceRealtimeSignal> get signals => _signals.stream;

  @override
  void connect(String deviceToken) {
    _releaseSocket();
    if (_signals.isClosed) return;

    _log('connecting to ${AppConfig.deviceRealtimeNamespace}');
    final socket = io.io(
      _config.deviceRealtimeUrl,
      buildDeviceSocketOptions(config: _config, deviceToken: deviceToken),
    );
    // Listeners first, connection second: auto-connect is off precisely so that
    // no event can be missed and none can be registered twice.
    _bindListeners(socket);
    _socket = socket;
    socket.connect();
  }

  @override
  void disconnect() {
    if (_socket != null) _log('disconnecting');
    _releaseSocket();
  }

  @override
  Future<void> dispose() async {
    _releaseSocket();
    if (!_signals.isClosed) await _signals.close();
  }

  void _bindListeners(io.Socket socket) {
    _listenerRemovers.addAll([
      socket.onConnect((_) {
        _log('connected');
        _emit(const RealtimeConnected());
      }),
      socket.on(deviceConnectedEvent, (Object? payload) {
        final confirmation = parseDeviceConnectedPayload(payload);
        if (confirmation == null) {
          _log('$deviceConnectedEvent ignored: unexpected payload');
          return;
        }
        // publicId is an identifier, not a credential: safe to log.
        _log('$deviceConnectedEvent for ${confirmation.publicId}');
        _emit(RealtimeIdentityConfirmed(confirmation));
      }),
      socket.onDisconnect((_) {
        _log('disconnected');
        _emit(const RealtimeDisconnected());
      }),
      socket.onConnectError((Object? error) {
        // Only the classification is logged. The raw error may carry the
        // handshake it failed on, and with it the Authorization payload.
        if (isUnauthorizedHandshakeError(error)) {
          _log('handshake rejected by the namespace');
          _emit(const RealtimeHandshakeRejected());
        } else {
          _log('connection attempt failed');
          _emit(const RealtimeConnectFailed());
        }
      }),
      socket.onReconnectAttempt((_) {
        _log('reconnect attempt');
        _emit(const RealtimeReconnectAttempt());
      }),
    ]);
  }

  /// Detaches every listener *before* closing, so the intentional close does
  /// not come back as a `disconnect` signal that would read as a network drop.
  void _releaseSocket() {
    final socket = _socket;
    _socket = null;
    for (final remove in _listenerRemovers) {
      remove();
    }
    _listenerRemovers.clear();
    socket?.dispose();
  }

  void _emit(DeviceRealtimeSignal signal) {
    if (_signals.isClosed) return;
    _signals.add(signal);
  }

  void _log(String message) {
    if (kDebugMode) developer.log(message, name: _loggerName);
  }
}
