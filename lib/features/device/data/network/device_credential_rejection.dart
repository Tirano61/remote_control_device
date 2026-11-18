import 'package:dio/dio.dart';

/// The application error code `POST /device-auth/login` puts in the JSON body
/// of a `401` when the backend checked the device credential and refused it.
///
/// `docs/backend/ENDPOINTS.md`, "Application error codes": it is the only code
/// the REST API emits, and only that endpoint emits it.
const String deviceCredentialRejectedCode = 'DEVICE_CREDENTIAL_REJECTED';

/// Whether [error] is the confirmed rejection the login contract defines:
///
/// ```text
/// HTTP 401
/// body decoded as a JSON object   (a JSON content type; text, HTML or an
///                                  empty body are never decoded to one)
/// body.code == DEVICE_CREDENTIAL_REJECTED, exactly
/// ```
///
/// Everything else is ambiguous: a `401` without the code, with another code,
/// with an HTML or empty body, any other status, or no response at all. The
/// `message` and `error` fields are ignored on purpose — `"Unauthorized"` is
/// what every 401 says, the backend's or not.
///
/// Only meaningful for the login call; the caller decides that by calling it
/// from there and nowhere else.
bool isDeviceCredentialRejection(DioException error) {
  if (error.type != DioExceptionType.badResponse) return false;
  final response = error.response;
  if (response == null || response.statusCode != 401) return false;
  final body = response.data;
  return body is Map && body['code'] == deviceCredentialRejectedCode;
}
