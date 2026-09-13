import 'dart:developer' as developer;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Debug-only traffic log that records **method, path and status code only**.
///
/// Bodies and headers are deliberately never logged: request bodies carry the
/// enrollment code and the `deviceSecret`, response bodies carry the
/// `deviceSecret` and the Device JWT, and headers carry `Authorization`.
class RequestLogInterceptor extends Interceptor {
  static const String _loggerName = 'http';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (kDebugMode) {
      developer.log('→ ${options.method} ${options.path}', name: _loggerName);
    }
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    if (kDebugMode) {
      developer.log(
        '← ${response.statusCode} ${response.requestOptions.method} '
        '${response.requestOptions.path}',
        name: _loggerName,
      );
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (kDebugMode) {
      developer.log(
        '× ${err.response?.statusCode ?? err.type.name} '
        '${err.requestOptions.method} ${err.requestOptions.path}',
        name: _loggerName,
      );
    }
    handler.next(err);
  }
}
