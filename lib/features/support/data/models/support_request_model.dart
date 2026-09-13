import 'package:remote_control_device/core/network/api_exception.dart';
import 'package:remote_control_device/features/device/data/models/json_parsing.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request_status.dart';
import 'package:remote_control_device/features/support/domain/entities/support_technician.dart';

/// The `supportRequest` payload documented in `ENDPOINTS.md`, shared by
/// `POST /support-requests`, `GET /support-requests/current` and the three
/// accept/reject/cancel responses:
///
/// ```json
/// {
///   "id": "8f14e45f-...",
///   "deviceId": "550e8400-...",
///   "status": "ASSIGNED",
///   "technicianId": "7c9e6679-...",
///   "technician": { "id": "7c9e6679-...", "name": "Ana Torres" },
///   "createdAt": "...", "assignedAt": "...",
///   "respondedAt": null, "closedAt": null
/// }
/// ```
///
/// Only `id`, `status` and `technician` are read. The rest is present in the
/// response and deliberately unused: `deviceId` because this client never
/// asserts its own identity, the timestamps because nothing displays them.
class SupportRequestModel {
  const SupportRequestModel({
    required this.id,
    required this.status,
    this.technician,
  });

  factory SupportRequestModel.fromJson(Map<String, dynamic> json) =>
      SupportRequestModel(
        id: json.requireString('id'),
        status: _statusFromWire(json.requireString('status')),
        technician: _technicianFromJson(json['technician']),
      );

  /// Reads the `{ "supportRequest": ... | null }` envelope of
  /// `GET /support-requests/current`.
  ///
  /// `null` is a documented, successful answer meaning "no active request", so
  /// it is returned as a value. A missing key is something else entirely — a
  /// response that is not the documented one — and fails loudly.
  static SupportRequestModel? fromCurrentEnvelope(Map<String, dynamic> json) {
    if (!json.containsKey('supportRequest')) {
      throw const ServerApiException(
        debugDetail: 'missing field "supportRequest"',
      );
    }
    final value = json['supportRequest'];
    if (value == null) return null;
    return SupportRequestModel.fromJson(asJsonObject(value));
  }

  final String id;
  final SupportRequestStatus status;
  final SupportTechnicianModel? technician;

  SupportRequest toEntity() => SupportRequest(
    id: id,
    status: status,
    technician: technician?.toEntity(),
  );
}

/// The technician block: `id` and `name` only, per the contract.
class SupportTechnicianModel {
  const SupportTechnicianModel({required this.id, required this.name});

  final String id;
  final String name;

  SupportTechnician toEntity() => SupportTechnician(id: id, name: name);
}

/// The only place in the application where support status strings exist.
SupportRequestStatus _statusFromWire(String value) => switch (value) {
  'WAITING' => SupportRequestStatus.waiting,
  'ASSIGNED' => SupportRequestStatus.assigned,
  'ACCEPTED' => SupportRequestStatus.accepted,
  'REJECTED' => SupportRequestStatus.rejected,
  'CANCELLED' => SupportRequestStatus.cancelled,
  'COMPLETED' => SupportRequestStatus.completed,
  // A status added to the backend after this build shipped. Rejecting the whole
  // response would leave the tablet unable to read its own state; naming it
  // `unknown` keeps the fact that something is there without pretending to know
  // what it means.
  _ => SupportRequestStatus.unknown,
};

/// Absent, `null`, or malformed all answer `null`.
///
/// The technician is decoration on an authorisation prompt, not the
/// authorisation itself, so a payload that does not match the contract costs
/// the user a name and nothing more. Throwing here would instead hide an
/// assigned request from the person who has to answer it.
SupportTechnicianModel? _technicianFromJson(Object? value) {
  if (value is! Map) return null;

  final id = value['id'];
  final name = value['name'];
  if (id is! String || id.isEmpty) return null;
  if (name is! String || name.isEmpty) return null;

  return SupportTechnicianModel(id: id, name: name);
}
