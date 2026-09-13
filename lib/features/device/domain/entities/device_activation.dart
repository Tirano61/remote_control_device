import 'package:equatable/equatable.dart';
import 'package:remote_control_device/features/device/domain/entities/device_credentials.dart';

/// Outcome of `POST /device-enrollment/activate`.
///
/// Mirrors exactly the documented response: `activated`, `deviceId`,
/// `publicId`, `name`, `deviceSecret`. The response carries no `isActive`
/// field, so this is not a [DeviceIdentity].
class DeviceActivation extends Equatable {
  const DeviceActivation({
    required this.activated,
    required this.deviceId,
    required this.publicId,
    required this.name,
    required this.deviceSecret,
  });

  final bool activated;
  final String deviceId;
  final String publicId;
  final String name;

  /// Delivered once and only here. Sensitive.
  final String deviceSecret;

  DeviceCredentials get credentials =>
      DeviceCredentials(deviceId: deviceId, deviceSecret: deviceSecret);

  @override
  List<Object?> get props => [activated, deviceId, publicId, name, deviceSecret];

  /// Redacted on purpose.
  @override
  String toString() =>
      'DeviceActivation(activated: $activated, deviceId: $deviceId, '
      'publicId: $publicId, name: $name, deviceSecret: <redacted>)';
}
