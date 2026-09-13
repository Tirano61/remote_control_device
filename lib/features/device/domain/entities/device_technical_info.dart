import 'package:equatable/equatable.dart';

/// Optional Android metadata accepted by `POST /device-enrollment/activate`.
///
/// Every field is optional in the contract and each one is length-constrained,
/// so an unavailable value is sent as absent rather than as an empty string —
/// the backend runs `forbidNonWhitelisted` validation and would reject it.
///
/// No invasive identifier (IMEI, serial number, advertising ID) is collected:
/// device identity comes from backend enrollment.
class DeviceTechnicalInfo extends Equatable {
  const DeviceTechnicalInfo({
    this.manufacturer,
    this.model,
    this.androidVersion,
    this.appVersion,
  });

  static const DeviceTechnicalInfo empty = DeviceTechnicalInfo();

  /// `Build.MANUFACTURER`, 1–100 chars.
  final String? manufacturer;

  /// `Build.MODEL`, 1–100 chars.
  final String? model;

  /// `Build.VERSION.RELEASE`, 1–50 chars.
  final String? androidVersion;

  /// `versionName` of the installed APK, 1–50 chars.
  final String? appVersion;

  @override
  List<Object?> get props => [manufacturer, model, androidVersion, appVersion];
}
