import 'package:equatable/equatable.dart';
import 'package:remote_control_device/features/device/domain/entities/device_identity.dart';

/// Outcome of `POST /device-auth/login`: the authenticated device plus the
/// temporary Device JWT that authorises `@DeviceAuth()` routes.
class DeviceSession extends Equatable {
  const DeviceSession({required this.device, required this.token});

  final DeviceIdentity device;

  /// Temporary Device JWT (24h by default). Not a permanent credential.
  final String token;

  @override
  List<Object?> get props => [device, token];

  /// Redacted on purpose: the Device JWT must never reach a log.
  @override
  String toString() => 'DeviceSession(device: $device, token: <redacted>)';
}
