import 'package:remote_control_device/features/device/domain/entities/device_technical_info.dart';

/// Request body of `POST /device-enrollment/activate`.
///
/// The backend validates with `whitelist: true` and
/// `forbidNonWhitelisted: true`: any extra property fails the whole request
/// with `400`, and every optional field has a minimum length of 1, so blank
/// values are omitted instead of being sent empty.
class DeviceActivationRequestModel {
  const DeviceActivationRequestModel({
    required this.publicId,
    required this.code,
    this.manufacturer,
    this.model,
    this.androidVersion,
    this.appVersion,
  });

  factory DeviceActivationRequestModel.fromTechnicalInfo({
    required String publicId,
    required String code,
    required DeviceTechnicalInfo technicalInfo,
  }) => DeviceActivationRequestModel(
    publicId: publicId,
    code: code,
    manufacturer: _sanitize(technicalInfo.manufacturer, maxLength: 100),
    model: _sanitize(technicalInfo.model, maxLength: 100),
    androidVersion: _sanitize(technicalInfo.androidVersion, maxLength: 50),
    appVersion: _sanitize(technicalInfo.appVersion, maxLength: 50),
  );

  final String publicId;
  final String code;
  final String? manufacturer;
  final String? model;
  final String? androidVersion;
  final String? appVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'publicId': publicId,
    'code': code,
    if (manufacturer != null) 'manufacturer': manufacturer,
    if (model != null) 'model': model,
    if (androidVersion != null) 'androidVersion': androidVersion,
    if (appVersion != null) 'appVersion': appVersion,
  };

  /// Trims, drops empty values and enforces the contract's length ceiling.
  static String? _sanitize(String? value, {required int maxLength}) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed.length <= maxLength
        ? trimmed
        : trimmed.substring(0, maxLength);
  }
}
