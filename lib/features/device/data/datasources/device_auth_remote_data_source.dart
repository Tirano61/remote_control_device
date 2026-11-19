import 'package:dio/dio.dart';
import 'package:remote_control_device/core/network/api_client.dart';
import 'package:remote_control_device/core/network/api_exception.dart';
import 'package:remote_control_device/core/network/device_auth_interceptor.dart';
import 'package:remote_control_device/features/device/data/models/device_identity_model.dart';
import 'package:remote_control_device/features/device/data/models/device_login_request_model.dart';
import 'package:remote_control_device/features/device/data/models/device_session_model.dart';
import 'package:remote_control_device/features/device/data/models/json_parsing.dart';
import 'package:remote_control_device/features/device/data/network/device_credential_rejection.dart';

abstract interface class DeviceAuthRemoteDataSource {
  /// Throws [DeviceCredentialRejectedApiException] only for the confirmed
  /// rejection the contract defines (`401` + `code: DEVICE_CREDENTIAL_REJECTED`).
  /// Any other `401` is an [UnauthorizedApiException], which says nothing about
  /// the credential.
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
        final Response<dynamic> response;
        try {
          response = await _client.dio.post<dynamic>(
            loginPath,
            data: request.toJson(),
          );
        } on DioException catch (error) {
          // Decided here, where the route is known: the code means something
          // only as an answer to this endpoint.
          if (isDeviceCredentialRejection(error)) {
            throw const DeviceCredentialRejectedApiException(
              debugDetail: '401 $deviceCredentialRejectedCode',
            );
          }
          rethrow;
        }
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
