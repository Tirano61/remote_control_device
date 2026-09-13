import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/network/api_exception.dart';

/// Single translation point from transport exceptions to domain failures.
Failure mapApiException(ApiException exception) => switch (exception) {
  NetworkApiException() => NetworkFailure(debugDetail: exception.debugDetail),
  UnauthorizedApiException() => AuthFailure(debugDetail: exception.debugDetail),
  BadRequestApiException() => ValidationFailure(debugDetail: exception.debugDetail),
  NotFoundApiException() => NotFoundFailure(debugDetail: exception.debugDetail),
  ConflictApiException() => ConflictFailure(debugDetail: exception.debugDetail),
  ServerApiException() => ServerFailure(debugDetail: exception.debugDetail),
  // A failed renewal already carries the reason the backend could not be
  // asked; re-deriving it from a status code would only lose detail.
  TokenRenewalApiException(:final failure) => failure,
};
