import 'package:dio/dio.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';

/// Attaches the Device JWT to the requests that are explicitly marked as
/// device-authenticated.
///
/// Opting in per request (instead of adding the header globally) keeps the
/// token away from the public endpoints `POST /device-enrollment/activate` and
/// `POST /device-auth/login`, which take no `Authorization` header at all.
class DeviceAuthInterceptor extends Interceptor {
  DeviceAuthInterceptor(this._tokenStore);

  /// Key placed in `RequestOptions.extra` to request the header.
  static const String requiresDeviceAuthKey = 'requiresDeviceAuth';

  /// `extra` map to spread into a request that must carry the Device JWT.
  static const Map<String, dynamic> requiresDeviceAuth = {
    requiresDeviceAuthKey: true,
  };

  final DeviceTokenStore _tokenStore;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.extra[requiresDeviceAuthKey] == true) {
      final token = _tokenStore.token;
      if (token != null) {
        options.headers['Authorization'] = 'Bearer $token';
      }
    }
    handler.next(options);
  }
}
