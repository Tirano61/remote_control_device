import 'package:remote_control_device/features/device/data/models/json_parsing.dart';
import 'package:remote_control_device/features/device/domain/entities/device_activation.dart';

/// Response of `POST /device-enrollment/activate`.
///
/// ```json
/// {
///   "activated": true,
///   "deviceId": "550e8400-...",
///   "publicId": "384-729-142",
///   "name": "Tablet Tolva 01",
///   "deviceSecret": "<opaque base64url secret>"
/// }
/// ```
class DeviceActivationModel {
  const DeviceActivationModel({
    required this.activated,
    required this.deviceId,
    required this.publicId,
    required this.name,
    required this.deviceSecret,
  });

  factory DeviceActivationModel.fromJson(Map<String, dynamic> json) =>
      DeviceActivationModel(
        activated: json.requireBool('activated'),
        deviceId: json.requireString('deviceId'),
        publicId: json.requireString('publicId'),
        name: json.requireString('name'),
        deviceSecret: json.requireString('deviceSecret'),
      );

  final bool activated;
  final String deviceId;
  final String publicId;
  final String name;
  final String deviceSecret;

  DeviceActivation toEntity() => DeviceActivation(
    activated: activated,
    deviceId: deviceId,
    publicId: publicId,
    name: name,
    deviceSecret: deviceSecret,
  );

  /// Redacted on purpose.
  @override
  String toString() => 'DeviceActivationModel(deviceId: $deviceId, '
      'publicId: $publicId, deviceSecret: <redacted>)';
}
