import 'package:remote_control_device/core/network/api_exception.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/device/data/datasources/device_enrollment_remote_data_source.dart';
import 'package:remote_control_device/features/device/data/models/device_activation_request_model.dart';
import 'package:remote_control_device/features/device/data/repositories/failure_mapper.dart';
import 'package:remote_control_device/features/device/domain/entities/device_activation.dart';
import 'package:remote_control_device/features/device/domain/entities/device_technical_info.dart';
import 'package:remote_control_device/features/device/domain/repositories/device_enrollment_repository.dart';

class DeviceEnrollmentRepositoryImpl implements DeviceEnrollmentRepository {
  const DeviceEnrollmentRepositoryImpl(this._remoteDataSource);

  final DeviceEnrollmentRemoteDataSource _remoteDataSource;

  @override
  Future<Result<DeviceActivation>> activate({
    required String publicId,
    required String code,
    required DeviceTechnicalInfo technicalInfo,
  }) async {
    try {
      final model = await _remoteDataSource.activate(
        DeviceActivationRequestModel.fromTechnicalInfo(
          publicId: publicId,
          code: code,
          technicalInfo: technicalInfo,
        ),
      );
      return Ok(model.toEntity());
    } on ApiException catch (exception) {
      return Err(mapApiException(exception));
    }
  }
}
