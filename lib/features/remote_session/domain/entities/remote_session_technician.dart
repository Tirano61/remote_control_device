import 'package:equatable/equatable.dart';

/// The technician block a remote session carries: `id` and `name`, nothing
/// else — no email, no roles, no token, exactly as the contract exposes it.
///
/// Deliberately its own type rather than the support feature's equivalent. The
/// two describe the same person but arrive in different payloads, and a remote
/// session must be readable on its own: the session panel has to name who is
/// connecting even in the moments when the support request is being re-read or
/// has already moved to `COMPLETED`. Sharing the type would buy nothing and
/// would make this feature depend on the other one's domain.
class RemoteSessionTechnician extends Equatable {
  const RemoteSessionTechnician({required this.id, required this.name});

  /// Backend UUID. An identifier, never a proof of authorisation.
  final String id;

  /// Display name, e.g. `Ana Torres`.
  final String name;

  @override
  List<Object?> get props => [id, name];
}
