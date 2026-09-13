import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/device/domain/entities/device_activation.dart';
import 'package:remote_control_device/features/device/domain/entities/device_technical_info.dart';

/// `POST /device-enrollment/activate` — public endpoint.
abstract interface class DeviceEnrollmentRepository {
  /// Exchanges [publicId] + [code] for the permanent device credential.
  ///
  /// A rejected activation (unknown `publicId`, inactive device, wrong,
  /// expired or already-used code) answers an undifferentiated `401`, surfaced
  /// here as an `AuthFailure`.
  Future<Result<DeviceActivation>> activate({
    required String publicId,
    required String code,
    required DeviceTechnicalInfo technicalInfo,
  });
}
