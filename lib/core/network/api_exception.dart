import 'package:remote_control_device/core/error/failures.dart';

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

/// HTTP 404.
///
/// On the support endpoints this means the request is gone or never belonged to
/// this device — the local copy is stale, not the call malformed. The contract
/// is explicit that the client re-reads state instead of parsing the message.
final class NotFoundApiException extends ApiException {
  const NotFoundApiException({super.debugDetail});
}

/// HTTP 409.
///
/// Always "the backend state is not what this client assumed": an active
/// request already exists, a transition is no longer legal, or a remote session
/// started in the meantime. The contract deliberately shares the status code
/// between those cases, so the only correct reaction is to re-read state.
final class ConflictApiException extends ApiException {
  const ConflictApiException({super.debugDetail});
}

/// Any other unexpected status, or a response body that could not be parsed.
final class ServerApiException extends ApiException {
  const ServerApiException({super.debugDetail});
}

/// A device-authenticated call answered `401` and the Device JWT could not be
/// renewed because the backend was unreachable or the secure store failed.
///
/// It carries the renewal's own [failure] so the reason survives to the UI
/// intact: nothing was learnt about the permanent credential, so the call is
/// retryable and the credential stays where it is.
final class TokenRenewalApiException extends ApiException {
  const TokenRenewalApiException(this.failure);

  final Failure failure;

  @override
  String? get debugDetail => failure.debugDetail;
}
