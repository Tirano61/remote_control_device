import 'package:remote_control_device/core/network/api_exception.dart';
import 'package:remote_control_device/features/device/data/models/json_parsing.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_technician.dart';

/// The `remoteSession` payload documented in `ENDPOINTS.md`, shared by
/// `GET /device/remote-sessions/current` and the
/// `POST /device/remote-sessions/:id/close` response:
///
/// ```json
/// {
///   "id": "3d1b9e64-...",
///   "supportRequestId": "8f14e45f-...",
///   "status": "CONNECTING",
///   "createdAt": "...", "connectedAt": null,
///   "endedAt": null, "endedBy": null,
///   "device": { "id": "550e8400-...", "publicId": "384-729-142",
///               "name": "Tablet Tolva 01", "isOnline": true },
///   "technician": { "id": "7c9e6679-...", "name": "Ana Torres" }
/// }
/// ```
///
/// Only `id`, `supportRequestId`, `status` and `technician` are read. The rest
/// is present in the response and deliberately unused: the `device` block
/// because this client never asserts or re-checks its own identity, the
/// timestamps and `endedBy` because nothing displays them.
class RemoteSessionModel {
  const RemoteSessionModel({
    required this.id,
    required this.supportRequestId,
    required this.status,
    this.technician,
  });

  factory RemoteSessionModel.fromJson(Map<String, dynamic> json) =>
      RemoteSessionModel(
        id: json.requireString('id'),
        supportRequestId: json.requireString('supportRequestId'),
        status: _statusFromWire(json.requireString('status')),
        technician: _technicianFromJson(json['technician']),
      );

  /// Reads the `{ "remoteSession": ... | null }` envelope of
  /// `GET /device/remote-sessions/current`.
  ///
  /// `null` is a documented, successful answer meaning "no live session", so it
  /// is returned as a value. A missing key is something else entirely — a
  /// response that is not the documented one — and fails loudly rather than
  /// being read as "no session", which is the one misreading that would silently
  /// drop a live session off the screen.
  static RemoteSessionModel? fromCurrentEnvelope(Map<String, dynamic> json) {
    if (!json.containsKey('remoteSession')) {
      throw const ServerApiException(
        debugDetail: 'missing field "remoteSession"',
      );
    }
    final value = json['remoteSession'];
    if (value == null) return null;
    return RemoteSessionModel.fromJson(asJsonObject(value));
  }

  final String id;
  final String supportRequestId;
  final RemoteSessionStatus status;
  final RemoteSessionTechnicianModel? technician;

  RemoteSession toEntity() => RemoteSession(
    id: id,
    supportRequestId: supportRequestId,
    status: status,
    technician: technician?.toEntity(),
  );
}

/// The technician block: `id` and `name` only, per the contract.
class RemoteSessionTechnicianModel {
  const RemoteSessionTechnicianModel({required this.id, required this.name});

  final String id;
  final String name;

  RemoteSessionTechnician toEntity() =>
      RemoteSessionTechnician(id: id, name: name);
}

/// The only place in the application where remote-session status strings exist.
RemoteSessionStatus _statusFromWire(String value) => switch (value) {
  'CONNECTING' => RemoteSessionStatus.connecting,
  'ACTIVE' => RemoteSessionStatus.active,
  'CLOSED' => RemoteSessionStatus.closed,
  // A status added to the backend after this build shipped. Naming it
  // `unknown` keeps the fact that a session is there without pretending to know
  // what it means — and `unknown` is not live, so nothing is shown as running.
  _ => RemoteSessionStatus.unknown,
};

/// Absent, `null`, or malformed all answer `null`.
///
/// The technician's name decorates a screen; it authorises nothing. A payload
/// that does not match the contract therefore costs the user a name and nothing
/// more — throwing here would instead hide a live session from the person who
/// has the right to end it.
RemoteSessionTechnicianModel? _technicianFromJson(Object? value) {
  if (value is! Map) return null;

  final id = value['id'];
  final name = value['name'];
  if (id is! String || id.isEmpty) return null;
  if (name is! String || name.isEmpty) return null;

  return RemoteSessionTechnicianModel(id: id, name: name);
}
