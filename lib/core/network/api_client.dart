import 'dart:io';

import 'package:dio/dio.dart';
import 'package:remote_control_device/core/config/app_config.dart';
import 'package:remote_control_device/core/network/api_exception.dart';
import 'package:remote_control_device/core/network/device_auth_interceptor.dart';
import 'package:remote_control_device/core/network/request_log_interceptor.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';

/// Centralises the HTTP configuration (base URL, timeouts, headers, auth
/// header injection) so that no data source has to know about them.
class ApiClient {
  ApiClient({required AppConfig config, required DeviceTokenStore tokenStore, Dio? dio})
    : dio = dio ?? Dio() {
    this.dio.options = this.dio.options.copyWith(
      baseUrl: config.backendBaseUrl,
      connectTimeout: config.connectTimeout,
      sendTimeout: config.sendTimeout,
      receiveTimeout: config.receiveTimeout,
      contentType: ContentType.json.mimeType,
      responseType: ResponseType.json,
      // Non-2xx statuses are handled explicitly by `ApiClient.guard`.
      validateStatus: (status) => status != null && status >= 200 && status < 300,
      // The backend never redirects. A 3xx comes from something in between,
      // and following it would send the request — and, on an authenticated
      // call, the Device JWT — somewhere that is not the backend, then report
      // whatever that place answers (a sign-in page, a 401) as if the backend
      // had said it. See `UnexpectedRedirectApiException`.
      followRedirects: false,
      maxRedirects: 0,
    );
    this.dio.interceptors
      ..add(DeviceAuthInterceptor(tokenStore))
      ..add(RequestLogInterceptor());
  }

  final Dio dio;

  /// Runs an HTTP call and normalises every transport/HTTP error into an
  /// [ApiException].
  ///
  /// The backend contract is explicit that clients must branch on the HTTP
  /// status code and not on the `message` string, so only the status is used
  /// here.
  static Future<T> guard<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on DioException catch (error) {
      throw _mapDioException(error);
    }
  }

  static ApiException _mapDioException(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
      case DioExceptionType.connectionError:
      case DioExceptionType.cancel:
        return NetworkApiException(debugDetail: error.type.name);
      case DioExceptionType.badCertificate:
        return NetworkApiException(debugDetail: 'badCertificate');
      case DioExceptionType.unknown:
        if (error.error is SocketException) {
          return const NetworkApiException(debugDetail: 'socket');
        }
        return NetworkApiException(debugDetail: error.type.name);
      case DioExceptionType.badResponse:
        return _mapStatusCode(error.response?.statusCode);
    }
  }

  static ApiException _mapStatusCode(int? statusCode) => switch (statusCode) {
    final int status when status >= 300 && status < 400 =>
      UnexpectedRedirectApiException(debugDetail: '$status'),
    400 => const BadRequestApiException(debugDetail: '400'),
    401 => const UnauthorizedApiException(debugDetail: '401'),
    404 => const NotFoundApiException(debugDetail: '404'),
    409 => const ConflictApiException(debugDetail: '409'),
    _ => ServerApiException(debugDetail: '${statusCode ?? 'no status'}'),
  };
}
