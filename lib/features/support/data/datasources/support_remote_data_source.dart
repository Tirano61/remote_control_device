import 'package:dio/dio.dart';
import 'package:remote_control_device/core/network/api_client.dart';
import 'package:remote_control_device/core/network/device_auth_interceptor.dart';
import 'package:remote_control_device/features/device/data/models/json_parsing.dart';
import 'package:remote_control_device/features/support/data/models/support_request_model.dart';

/// The `/support-requests` device endpoints.
///
/// Every one of them is `@DeviceAuth()`-protected and none of them accepts a
/// `deviceId`: the backend resolves the device from the Device JWT. Nothing
/// here therefore puts an identifier in a body, a query or a header — the three
/// creation/response paths carry an empty request body exactly as documented.
abstract interface class SupportRemoteDataSource {
  Future<SupportRequestModel> create();

  /// `null` when the device has no active request.
  Future<SupportRequestModel?> current();

  Future<SupportRequestModel> accept(String id);

  Future<SupportRequestModel> reject(String id);

  Future<SupportRequestModel> cancel(String id);
}

class SupportRemoteDataSourceImpl implements SupportRemoteDataSource {
  const SupportRemoteDataSourceImpl(this._client);

  static const String basePath = '/support-requests';
  static const String currentPath = '$basePath/current';

  static String acceptPath(String id) => '$basePath/$id/accept';

  static String rejectPath(String id) => '$basePath/$id/reject';

  static String cancelPath(String id) => '$basePath/$id/cancel';

  final ApiClient _client;

  @override
  Future<SupportRequestModel> create() => _post(basePath);

  @override
  Future<SupportRequestModel?> current() => ApiClient.guard(() async {
    final response = await _client.dio.get<dynamic>(
      currentPath,
      options: Options(extra: DeviceAuthInterceptor.requiresDeviceAuth),
    );
    return SupportRequestModel.fromCurrentEnvelope(asJsonObject(response.data));
  });

  @override
  Future<SupportRequestModel> accept(String id) => _post(acceptPath(id));

  @override
  Future<SupportRequestModel> reject(String id) => _post(rejectPath(id));

  @override
  Future<SupportRequestModel> cancel(String id) => _post(cancelPath(id));

  /// All four writes share one shape: no body at all, the Device JWT as the
  /// only thing identifying the caller, and the updated request as the answer.
  Future<SupportRequestModel> _post(String path) => ApiClient.guard(() async {
    final response = await _client.dio.post<dynamic>(
      path,
      options: Options(extra: DeviceAuthInterceptor.requiresDeviceAuth),
    );
    return SupportRequestModel.fromJson(asJsonObject(response.data));
  });
}
