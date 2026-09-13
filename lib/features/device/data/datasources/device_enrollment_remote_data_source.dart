import 'package:remote_control_device/core/network/api_client.dart';
import 'package:remote_control_device/features/device/data/models/device_activation_model.dart';
import 'package:remote_control_device/features/device/data/models/device_activation_request_model.dart';
import 'package:remote_control_device/features/device/data/models/json_parsing.dart';

abstract interface class DeviceEnrollmentRemoteDataSource {
  Future<DeviceActivationModel> activate(DeviceActivationRequestModel request);
}

class DeviceEnrollmentRemoteDataSourceImpl
    implements DeviceEnrollmentRemoteDataSource {
  const DeviceEnrollmentRemoteDataSourceImpl(this._client);

  /// Public endpoint: no `Authorization` header.
  static const String activatePath = '/device-enrollment/activate';

  final ApiClient _client;

  @override
  Future<DeviceActivationModel> activate(
    DeviceActivationRequestModel request,
  ) => ApiClient.guard(() async {
    final response = await _client.dio.post<dynamic>(
      activatePath,
      data: request.toJson(),
    );
    return DeviceActivationModel.fromJson(asJsonObject(response.data));
  });
}
