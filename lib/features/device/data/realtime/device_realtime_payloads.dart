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
RealtimeRemoteSessionCreated? parseRemoteSessionCreatedPayload(
  Object? payload,
) {
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

/// Reads the `remote-session:active` payload documented in `REALTIME.md`:
///
/// ```json
/// { "remoteSessionId": "3d1b9e64-..." }
/// ```
///
/// One field, and the contract calls it "deliberately minimal": the event says
/// *which* session moved, never what it moved to. So nothing else is read, and
/// in particular no `status` or `connectedAt` is invented here — both come from
/// `GET /device/remote-sessions/current`, which is the only thing this notice
/// is allowed to cause.
///
/// Returns `null` for anything that does not carry a usable session id.
/// Realtime payloads are untrusted input, and a malformed one must produce no
/// signal at all rather than a half-built one.
RealtimeRemoteSessionActivated? parseRemoteSessionActivePayload(
  Object? payload,
) {
  if (payload is! Map) return null;

  final remoteSessionId = payload['remoteSessionId'];
  if (remoteSessionId is! String || remoteSessionId.isEmpty) return null;

  return RealtimeRemoteSessionActivated(remoteSessionId);
}

/// Reads the `remote-session:closed` payload documented in `REALTIME.md`:
///
/// ```json
/// { "remoteSessionId": "3d1b9e64-...", "endedBy": "TECHNICIAN" }
/// ```
///
/// Only `remoteSessionId` is required. `endedBy` is carried when it is a short
/// upper-case token and dropped otherwise: it is only shown to the user, and —
/// being a `RemoteSessionEndedBy` — may grow values this build has never heard
/// of (`SYSTEM` is the one the backend's automatic close writes). Refusing the
/// event over a field that changes nothing would turn a contract extension into
/// a tablet that keeps obeying a technician whose session is over.
///
/// Returns `null` for anything that does not carry a usable session id.
RealtimeRemoteSessionClosed? parseRemoteSessionClosedPayload(Object? payload) {
  if (payload is! Map) return null;

  final remoteSessionId = payload['remoteSessionId'];
  if (remoteSessionId is! String || remoteSessionId.isEmpty) return null;

  final endedBy = payload['endedBy'];
  return RealtimeRemoteSessionClosed(
    remoteSessionId,
    endedBy: endedBy is String && _endedByToken.hasMatch(endedBy)
        ? endedBy
        : null,
  );
}

/// What an `endedBy` value may look like to be carried at all.
final RegExp _endedByToken = RegExp(r'^[A-Z_]{1,32}$');

/// `data.code` of a handshake the backend checked and refused
/// (`REALTIME.md`, "Handshake errors").
const String handshakeUnauthorizedCode = 'DEVICE_AUTH_UNAUTHORIZED';

/// `data.code` of a handshake the backend could not finish checking: its
/// database failed, not the token.
const String handshakeUnavailableCode = 'DEVICE_AUTH_UNAVAILABLE';

/// The `connect_error` message of a refused handshake. Today it travels with
/// [handshakeUnauthorizedCode]; a backend older than the codes sent it alone,
/// for every refusal, its own failures included.
const String handshakeRejectedMessage = 'Unauthorized';

/// What a `connect_error` says about the token that was presented.
enum HandshakeErrorKind {
  /// `data.code` is [handshakeUnauthorizedCode]: the token was checked and is
  /// not accepted now. Renew it. Still not a revocation: only the login's
  /// `401 DEVICE_CREDENTIAL_REJECTED` says that.
  unauthorized,

  /// No `data.code`, and the message is exactly [handshakeRejectedMessage]: a
  /// backend that predates the codes. It may have been a database failure, but
  /// it may as well be an expired token, so the token is renewed, as before.
  legacyUnauthorized,

  /// `data.code` is [handshakeUnavailableCode]: the backend could not check
  /// the token. Nothing is known about it — it is neither refused nor
  /// accepted. Present it again later; do not renew it.
  unavailable,

  /// Anything else: a transport failure, an unknown code, a malformed packet,
  /// another message. It proves nothing about the token and grants nothing.
  unrecognized,
}

/// Classifies a `connect_error`.
///
/// `socket_io_client` 3.1.6 hands the `CONNECT_ERROR` packet data over as is:
/// a map with `message` and, from a backend that knows the codes, `data.code`.
/// A transport failure arrives instead as an exception, a string, or a map of
/// another shape (`{msg, desc, type: TransportError}`,
/// `{error: 'server error', code: …}`), so only `data.code` — never a `code` at
/// the top level — counts.
///
/// Only `data.code` decides between the two documented refusals. The message
/// is read for one thing: recognising a backend older than the codes, by the
/// exact text it used to send. A message that merely mentions "unauthorized",
/// a proxy page, or the text `Service unavailable` without its code decides
/// nothing.
HandshakeErrorKind classifyHandshakeError(Object? error) {
  final code = _handshakeErrorCode(error);
  if (code != null) {
    return switch (code) {
      handshakeUnauthorizedCode => HandshakeErrorKind.unauthorized,
      handshakeUnavailableCode => HandshakeErrorKind.unavailable,
      // A code this client does not know: not one it can act on as either.
      _ => HandshakeErrorKind.unrecognized,
    };
  }
  return _handshakeErrorMessage(error) == handshakeRejectedMessage
      ? HandshakeErrorKind.legacyUnauthorized
      : HandshakeErrorKind.unrecognized;
}

/// `data.code` when it is there and is a string; `null` otherwise, including
/// when `data` is not a map or `code` is of another type.
String? _handshakeErrorCode(Object? error) {
  if (error is! Map) return null;
  final data = error['data'];
  if (data is! Map) return null;
  final code = data['code'];
  return code is String ? code : null;
}

String? _handshakeErrorMessage(Object? error) {
  if (error is String) return error;
  if (error is Map) {
    final message = error['message'];
    if (message is String) return message;
  }
  return null;
}
