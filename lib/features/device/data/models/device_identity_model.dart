import 'package:remote_control_device/features/device/data/models/json_parsing.dart';
import 'package:remote_control_device/features/device/domain/entities/device_identity.dart';

/// Public device payload shared by `POST /device-auth/login` and
/// `GET /device-auth/check-status`.
///
/// ```json
/// {
///   "id": "550e8400-...",
///   "publicId": "384-729-142",
///   "name": "Tablet Tolva 01",
///   "isActive": true
/// }
/// ```
class DeviceIdentityModel {
  const DeviceIdentityModel({
    required this.id,
    required this.publicId,
    required this.name,
    required this.isActive,
  });

  factory DeviceIdentityModel.fromJson(Map<String, dynamic> json) =>
      DeviceIdentityModel(
        id: json.requireString('id'),
        publicId: json.requireString('publicId'),
        name: json.requireString('name'),
        isActive: json.requireBool('isActive'),
      );

  final String id;
  final String publicId;
  final String name;
  final bool isActive;

  DeviceIdentity toEntity() => DeviceIdentity(
    id: id,
    publicId: publicId,
    name: name,
    isActive: isActive,
  );
}
