import 'package:equatable/equatable.dart';

/// Public device information returned by `POST /device-auth/login` and
/// `GET /device-auth/check-status`.
///
/// Nothing here is sensitive; [publicId] is an identifier, not a credential,
/// and may be displayed to the user.
class DeviceIdentity extends Equatable {
  const DeviceIdentity({
    required this.id,
    required this.publicId,
    required this.name,
    required this.isActive,
  });

  /// Backend UUID.
  final String id;

  /// Human-readable identifier, formatted `384-729-142`.
  final String publicId;

  /// Name assigned by the technician, e.g. `Tablet Tolva 01`.
  final String name;

  final bool isActive;

  @override
  List<Object?> get props => [id, publicId, name, isActive];
}
