import 'package:equatable/equatable.dart';

/// Identity the backend resolved from the Device JWT during the Socket.IO
/// handshake, delivered by the `device:connected` event (REALTIME.md).
///
/// It is a *confirmation*, not a source of identity: the persistent identity of
/// the device comes from `GET /device-auth/check-status`. This value only lets
/// the tablet verify it is connected with the credential it believes it holds.
class DeviceRealtimeConfirmation extends Equatable {
  const DeviceRealtimeConfirmation({
    required this.deviceId,
    required this.publicId,
  });

  /// Backend UUID of the device the socket authenticated as.
  final String deviceId;

  /// Human-readable identifier, formatted `384-729-142`. Not a credential.
  final String publicId;

  /// `true` when this confirmation matches the identity already established
  /// over REST. A mismatch means the socket is authenticated as another device.
  bool matches({required String deviceId, required String publicId}) =>
      this.deviceId == deviceId && this.publicId == publicId;

  @override
  List<Object?> get props => [deviceId, publicId];
}
