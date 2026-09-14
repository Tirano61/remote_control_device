import 'package:dio/dio.dart';
import 'package:remote_control_device/core/network/api_client.dart';
import 'package:remote_control_device/core/network/device_auth_interceptor.dart';
import 'package:remote_control_device/features/device/data/models/json_parsing.dart';
import 'package:remote_control_device/features/remote_session/data/models/remote_session_model.dart';

/// The `/device/remote-sessions` endpoints.
///
/// A different prefix from the technician controller, and `@DeviceAuth()`
/// -protected as a whole. Neither call accepts a `deviceId` or a
/// `supportRequestId`: the backend resolves the device from the Device JWT and
/// the session from the path. Nothing here therefore puts an identifier in a
/// body, a query or a header — the close call carries an empty body exactly as
/// documented.
abstract interface class RemoteSessionRemoteDataSource {
  /// `null` when the device has no live session.
  Future<RemoteSessionModel?> current();

  Future<RemoteSessionModel> close(String id);
}

class RemoteSessionRemoteDataSourceImpl implements RemoteSessionRemoteDataSource {
  const RemoteSessionRemoteDataSourceImpl(this._client);

  static const String basePath = '/device/remote-sessions';
  static const String currentPath = '$basePath/current';

  static String closePath(String id) => '$basePath/$id/close';

  final ApiClient _client;

  @override
  Future<RemoteSessionModel?> current() => ApiClient.guard(() async {
    final response = await _client.dio.get<dynamic>(
      currentPath,
      options: Options(extra: DeviceAuthInterceptor.requiresDeviceAuth),
    );
    return RemoteSessionModel.fromCurrentEnvelope(asJsonObject(response.data));
  });

  @override
  Future<RemoteSessionModel> close(String id) => ApiClient.guard(() async {
    final response = await _client.dio.post<dynamic>(
      closePath(id),
      options: Options(extra: DeviceAuthInterceptor.requiresDeviceAuth),
    );
    // The closed session comes back in this response — which is exactly why the
    // backend emits no `remote-session:closed` for a device-initiated close.
    return RemoteSessionModel.fromJson(asJsonObject(response.data));
  });
}
