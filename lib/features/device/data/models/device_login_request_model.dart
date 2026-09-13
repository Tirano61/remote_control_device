import 'package:remote_control_device/features/device/domain/entities/device_credentials.dart';

/// Request body of `POST /device-auth/login`.
///
/// `publicId` is intentionally absent: the contract states it does not
/// authenticate and the endpoint rejects unknown properties.
class DeviceLoginRequestModel {
  const DeviceLoginRequestModel({
    required this.deviceId,
    required this.deviceSecret,
  });

  factory DeviceLoginRequestModel.fromCredentials(
    DeviceCredentials credentials,
  ) => DeviceLoginRequestModel(
    deviceId: credentials.deviceId,
    deviceSecret: credentials.deviceSecret,
  );

  final String deviceId;
  final String deviceSecret;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'deviceId': deviceId,
    'deviceSecret': deviceSecret,
  };

  /// Redacted on purpose: this object carries the permanent credential.
  @override
  String toString() =>
      'DeviceLoginRequestModel(deviceId: $deviceId, deviceSecret: <redacted>)';
}
