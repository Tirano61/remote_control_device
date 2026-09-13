import 'package:equatable/equatable.dart';

/// The technician attached to an assigned support request.
///
/// The contract exposes `id` and `name` to the device and nothing else — no
/// email, no roles, no token — and this entity deliberately mirrors that: the
/// user is asked to authorise a person, so a name is all the screen needs.
class SupportTechnician extends Equatable {
  const SupportTechnician({required this.id, required this.name});

  /// Backend UUID. An identifier, never a proof of authorisation: the backend
  /// decides who may act on a request.
  final String id;

  /// Display name, e.g. `Ana Torres`.
  final String name;

  @override
  List<Object?> get props => [id, name];
}
