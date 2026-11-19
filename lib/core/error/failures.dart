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

/// HTTP 401 that does not confirm anything about the permanent credential:
/// a refused Device JWT, or a `401` produced by something in front of the
/// backend. The stored credential is kept; the device is simply not
/// authenticated right now.
///
/// On `POST /device-enrollment/activate` it is the activation being refused
/// (wrong `publicId` or code), which involves no stored credential at all.
final class AuthFailure extends Failure {
  const AuthFailure({super.debugDetail});
}

/// `POST /device-auth/login` answered `401 DEVICE_CREDENTIAL_REJECTED`: the
/// backend refused the stored credential.
///
/// The contract does not say why, so this cannot tell a deactivated device
/// (the same credential works again once reactivated) from a replaced one
/// (re-enrollment needed). The credential is therefore kept; only authorisation
/// is withdrawn.
final class CredentialRejectedFailure extends Failure {
  const CredentialRejectedFailure({super.debugDetail});
}

/// HTTP 400. The request did not pass backend validation.
final class ValidationFailure extends Failure {
  const ValidationFailure({super.debugDetail});
}

/// HTTP 404. The resource does not exist for this device — typically a locally
/// held id that the backend no longer recognises. The client re-synchronises
/// instead of treating it as a hard error.
final class NotFoundFailure extends Failure {
  const NotFoundFailure({super.debugDetail});
}

/// HTTP 409. The backend state no longer matches what the client assumed. The
/// contract shares this status between several causes on purpose, so the only
/// correct reaction is to re-read state rather than to interpret a message.
final class ConflictFailure extends Failure {
  const ConflictFailure({super.debugDetail});
}

/// HTTP 5xx, or any response the client could not interpret.
final class ServerFailure extends Failure {
  const ServerFailure({super.debugDetail});
}

/// Secure storage could not be read or written.
final class StorageFailure extends Failure {
  const StorageFailure({super.debugDetail});
}
