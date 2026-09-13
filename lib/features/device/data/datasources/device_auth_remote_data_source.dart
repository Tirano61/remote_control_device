import 'package:dio/dio.dart';
import 'package:remote_control_device/core/network/api_client.dart';
import 'package:remote_control_device/core/network/device_auth_interceptor.dart';
import 'package:remote_control_device/features/device/data/models/device_identity_model.dart';
import 'package:remote_control_device/features/device/data/models/device_login_request_model.dart';
import 'package:remote_control_device/features/device/data/models/device_session_model.dart';
import 'package:remote_control_device/features/device/data/models/json_parsing.dart';

abstract interface class DeviceAuthRemoteDataSource {
  Future<DeviceSessionModel> login(DeviceLoginRequestModel request);

  Future<DeviceIdentityModel> checkStatus();
}

class DeviceAuthRemoteDataSourceImpl implements DeviceAuthRemoteDataSource {
  const DeviceAuthRemoteDataSourceImpl(this._client);

  /// Public endpoint: the device credential in the body is what authorises it.
  static const String loginPath = '/device-auth/login';

  /// Device JWT required.
  static const String checkStatusPath = '/device-auth/check-status';

  final ApiClient _client;

  @override
  Future<DeviceSessionModel> login(DeviceLoginRequestModel request) =>
      ApiClient.guard(() async {
        final response = await _client.dio.post<dynamic>(
          loginPath,
          data: request.toJson(),
        );
        return DeviceSessionModel.fromJson(asJsonObject(response.data));
      });

  @override
  Future<DeviceIdentityModel> checkStatus() => ApiClient.guard(() async {
    final response = await _client.dio.get<dynamic>(
      checkStatusPath,
      options: Options(extra: DeviceAuthInterceptor.requiresDeviceAuth),
    );
    return DeviceIdentityModel.fromJson(asJsonObject(response.data));
  });
}
