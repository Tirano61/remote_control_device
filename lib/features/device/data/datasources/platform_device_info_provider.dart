import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:remote_control_device/features/device/domain/entities/device_technical_info.dart';
import 'package:remote_control_device/features/device/domain/services/device_info_provider.dart';

/// Collects the non-invasive Android metadata accepted by the enrollment
/// endpoint: manufacturer, model, Android release and app version.
///
/// No IMEI, serial number or advertising ID is read — identity comes from the
/// backend, not from the hardware.
class PlatformDeviceInfoProvider implements DeviceInfoProvider {
  PlatformDeviceInfoProvider({DeviceInfoPlugin? deviceInfoPlugin})
    : _deviceInfo = deviceInfoPlugin ?? DeviceInfoPlugin();

  final DeviceInfoPlugin _deviceInfo;

  @override
  Future<DeviceTechnicalInfo> collect() async {
    final appVersion = await _appVersion();

    if (!Platform.isAndroid) {
      return DeviceTechnicalInfo(appVersion: appVersion);
    }

    try {
      final android = await _deviceInfo.androidInfo;
      return DeviceTechnicalInfo(
        manufacturer: android.manufacturer,
        model: android.model,
        androidVersion: android.version.release,
        appVersion: appVersion,
      );
    } on Exception {
      // Metadata is optional in the contract: never block an activation on it.
      return DeviceTechnicalInfo(appVersion: appVersion);
    }
  }

  Future<String?> _appVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      return packageInfo.version;
    } on Exception {
      return null;
    }
  }
}
