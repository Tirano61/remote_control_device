import 'package:remote_control_device/features/device/domain/entities/device_realtime_confirmation.dart';

/// Reads the `device:connected` payload documented in `REALTIME.md`:
///
/// ```json
/// { "deviceId": "550e8400-...", "publicId": "384-729-142" }
/// ```
///
/// Returns `null` for anything that does not match, instead of throwing or
/// filling in defaults. A realtime payload is untrusted input shaped by whatever
/// is on the other end of the socket, and a malformed one must never be able to
/// turn into a half-built identity.
DeviceRealtimeConfirmation? parseDeviceConnectedPayload(Object? payload) {
  if (payload is! Map) return null;

  final deviceId = payload['deviceId'];
  final publicId = payload['publicId'];
  if (deviceId is! String || deviceId.isEmpty) return null;
  if (publicId is! String || publicId.isEmpty) return null;

  return DeviceRealtimeConfirmation(deviceId: deviceId, publicId: publicId);
}

/// Whether a `connect_error` is the namespace middleware refusing the token.
///
/// The backend answers a single generic `Unauthorized` for every rejection
/// reason. Socket.IO delivers it as the `CONNECT_ERROR` packet data — a map
/// carrying `message` — while a transport failure (no network, timeout, backend
/// down) arrives as an exception object instead. Telling them apart is what
/// decides between "renew the Device JWT" and "wait for the network".
///
/// Anything unrecognised is treated as a transport failure: assuming an
/// authentication problem would make a flaky network trigger login attempts.
bool isUnauthorizedHandshakeError(Object? error) {
  final message = _handshakeErrorMessage(error);
  return message != null && message.toLowerCase().contains('unauthorized');
}

String? _handshakeErrorMessage(Object? error) {
  if (error is String) return error;
  if (error is Map) {
    final message = error['message'];
    if (message is String) return message;
  }
  return null;
}
