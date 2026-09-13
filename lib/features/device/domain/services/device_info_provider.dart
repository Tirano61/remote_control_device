import 'package:remote_control_device/features/device/domain/entities/device_technical_info.dart';

/// Port that supplies the optional Android metadata sent during enrollment.
abstract interface class DeviceInfoProvider {
  /// Never throws: metadata is optional in the enrollment contract, so a
  /// failure to read it must not prevent the device from being activated.
  Future<DeviceTechnicalInfo> collect();
}
