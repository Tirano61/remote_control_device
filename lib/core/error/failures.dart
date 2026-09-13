import 'package:equatable/equatable.dart';

/// Transport-agnostic error categories the presentation layer is allowed to
/// branch on.
///
/// The UI must never branch on human-readable backend messages: the REST
/// contract states that `message` texts are not part of the contract and may
/// change. [debugDetail] exists only for local diagnostics and must never be
/// rendered to the end user.
sealed class Failure extends Equatable {
  const Failure({this.debugDetail});

  /// Technical detail kept for logs. Never shown in the UI.
  final String? debugDetail;

  @override
  List<Object?> get props => [runtimeType];
}

/// The backend could not be reached: no connectivity, timeout, DNS failure,
/// server down. Locally stored credentials remain valid and must be kept.
final class NetworkFailure extends Failure {
  const NetworkFailure({super.debugDetail});
}

/// HTTP 401. The credential presented was rejected by the backend.
final class AuthFailure extends Failure {
  const AuthFailure({super.debugDetail});
}

/// HTTP 400. The request did not pass backend validation.
final class ValidationFailure extends Failure {
  const ValidationFailure({super.debugDetail});
}

/// HTTP 5xx, or any response the client could not interpret.
final class ServerFailure extends Failure {
  const ServerFailure({super.debugDetail});
}

/// Secure storage could not be read or written.
final class StorageFailure extends Failure {
  const StorageFailure({super.debugDetail});
}
