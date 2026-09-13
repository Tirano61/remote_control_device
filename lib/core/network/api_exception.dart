/// Exceptions raised by the data layer when an HTTP call does not succeed.
///
/// Repositories translate these into `Failure` values; nothing above the data
/// layer sees them.
sealed class ApiException implements Exception {
  const ApiException({this.debugDetail});

  final String? debugDetail;

  @override
  String toString() => '$runtimeType(${debugDetail ?? 'no detail'})';
}

/// The request never produced a usable HTTP response.
final class NetworkApiException extends ApiException {
  const NetworkApiException({super.debugDetail});
}

/// HTTP 401.
final class UnauthorizedApiException extends ApiException {
  const UnauthorizedApiException({super.debugDetail});
}

/// HTTP 400.
final class BadRequestApiException extends ApiException {
  const BadRequestApiException({super.debugDetail});
}

/// Any other unexpected status, or a response body that could not be parsed.
final class ServerApiException extends ApiException {
  const ServerApiException({super.debugDetail});
}
