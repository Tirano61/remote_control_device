import 'package:remote_control_device/core/network/api_exception.dart';

/// Helpers that fail loudly — as a [ServerApiException] — when a response does
/// not match the documented contract, instead of silently producing defaults.
extension ContractJson on Map<String, dynamic> {
  String requireString(String key) {
    final value = this[key];
    if (value is String && value.isNotEmpty) return value;
    throw ServerApiException(debugDetail: 'missing or invalid field "$key"');
  }

  bool requireBool(String key) {
    final value = this[key];
    if (value is bool) return value;
    throw ServerApiException(debugDetail: 'missing or invalid field "$key"');
  }
}

/// Validates that a response payload is the JSON object the contract documents.
Map<String, dynamic> asJsonObject(dynamic data) {
  if (data is Map<String, dynamic>) return data;
  throw const ServerApiException(debugDetail: 'response body is not a JSON object');
}
