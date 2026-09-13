import 'package:equatable/equatable.dart';

/// Permanent identity of this installation.
///
/// This pair is what restores a session after a restart — never the Device JWT.
/// [deviceSecret] is delivered exactly once by
/// `POST /device-enrollment/activate` and is stored only in secure storage.
class DeviceCredentials extends Equatable {
  const DeviceCredentials({required this.deviceId, required this.deviceSecret});

  /// Backend UUID of the device. Assigned by the backend, never generated here.
  final String deviceId;

  /// Permanent high-entropy credential. Sensitive.
  final String deviceSecret;

  @override
  List<Object?> get props => [deviceId, deviceSecret];

  /// Redacted on purpose: the secret must never reach a log or a crash report.
  @override
  String toString() => 'DeviceCredentials(deviceId: $deviceId, deviceSecret: <redacted>)';
}
