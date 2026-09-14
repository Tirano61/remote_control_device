import 'package:remote_control_device/features/device/domain/entities/device_realtime_confirmation.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';

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

/// Reads the `support:assigned` payload documented in `REALTIME.md`:
///
/// ```json
/// {
///   "supportRequestId": "8f14e45f-...",
///   "technician": { "id": "7c9e6679-...", "name": "Ana Torres" }
/// }
/// ```
///
/// The whole documented shape is required — a payload missing the technician
/// block is not the event this client knows about — but only the identifiers
/// travel onwards. The technician's name is deliberately dropped here: what is
/// shown to the user comes from `GET /support-requests/current`, so carrying a
/// name off the socket could only tempt a screen into trusting it.
///
/// Returns `null` for anything that does not match. Realtime payloads are
/// untrusted input, and a malformed one must produce no signal at all rather
/// than a half-built one.
RealtimeSupportAssigned? parseSupportAssignedPayload(Object? payload) {
  if (payload is! Map) return null;

  final supportRequestId = payload['supportRequestId'];
  if (supportRequestId is! String || supportRequestId.isEmpty) return null;

  final technician = payload['technician'];
  if (technician is! Map) return null;

  final technicianId = technician['id'];
  final technicianName = technician['name'];
  if (technicianId is! String || technicianId.isEmpty) return null;
  if (technicianName is! String || technicianName.isEmpty) return null;

  return RealtimeSupportAssigned(
    supportRequestId: supportRequestId,
    technicianId: technicianId,
  );
}

/// Reads the `remote-session:created` payload documented in `REALTIME.md`:
///
/// ```json
/// {
///   "remoteSessionId": "3d1b9e64-...",
///   "supportRequestId": "8f14e45f-...",
///   "technician": { "id": "7c9e6679-...", "name": "Ana Torres" }
/// }
/// ```
///
/// The whole documented shape is required — a payload missing the technician
/// block is not the event this client knows about — but only the identifiers
/// travel onwards, and not even those are used to build a session: what the
/// user is shown comes from `GET /device/remote-sessions/current`. Carrying the
/// name off the socket could only tempt a screen into trusting it.
///
/// Returns `null` for anything that does not match. Realtime payloads are
/// untrusted input shaped by whatever is on the other end of the socket, and a
/// malformed one must produce no signal at all rather than a half-built one.
RealtimeRemoteSessionCreated? parseRemoteSessionCreatedPayload(Object? payload) {
  if (payload is! Map) return null;

  final remoteSessionId = payload['remoteSessionId'];
  if (remoteSessionId is! String || remoteSessionId.isEmpty) return null;

  final supportRequestId = payload['supportRequestId'];
  if (supportRequestId is! String || supportRequestId.isEmpty) return null;

  final technician = payload['technician'];
  if (technician is! Map) return null;

  final technicianId = technician['id'];
  final technicianName = technician['name'];
  if (technicianId is! String || technicianId.isEmpty) return null;
  if (technicianName is! String || technicianName.isEmpty) return null;

  return RealtimeRemoteSessionCreated(
    remoteSessionId: remoteSessionId,
    supportRequestId: supportRequestId,
    technicianId: technicianId,
  );
}

/// Reads the `remote-session:closed` payload documented in `REALTIME.md`:
///
/// ```json
/// { "remoteSessionId": "3d1b9e64-...", "endedBy": "TECHNICIAN" }
/// ```
///
/// Only `remoteSessionId` is required. `endedBy` is documented, is read by
/// nothing in this client, and — being a `RemoteSessionEndedBy` — may grow
/// values this build has never heard of; refusing the event over a field that
/// changes nothing would turn a contract extension into a tablet stuck on
/// "assistance in progress". What the event means is "ask again", and the
/// answer to that comes from REST.
///
/// Returns `null` for anything that does not carry a usable session id.
RealtimeRemoteSessionClosed? parseRemoteSessionClosedPayload(Object? payload) {
  if (payload is! Map) return null;

  final remoteSessionId = payload['remoteSessionId'];
  if (remoteSessionId is! String || remoteSessionId.isEmpty) return null;

  return RealtimeRemoteSessionClosed(remoteSessionId);
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
