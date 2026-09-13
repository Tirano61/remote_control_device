import 'package:remote_control_device/features/device/data/models/device_identity_model.dart';
import 'package:remote_control_device/features/device/data/models/json_parsing.dart';
import 'package:remote_control_device/features/device/domain/entities/device_session.dart';

/// Response of `POST /device-auth/login`: the public device payload plus the
/// `token` field, which only this endpoint returns.
class DeviceSessionModel {
  const DeviceSessionModel({required this.device, required this.token});

  factory DeviceSessionModel.fromJson(Map<String, dynamic> json) =>
      DeviceSessionModel(
        device: DeviceIdentityModel.fromJson(json),
        token: json.requireString('token'),
      );

  final DeviceIdentityModel device;
  final String token;

  DeviceSession toEntity() =>
      DeviceSession(device: device.toEntity(), token: token);

  /// Redacted on purpose.
  @override
  String toString() => 'DeviceSessionModel(deviceId: ${device.id}, token: <redacted>)';
}
