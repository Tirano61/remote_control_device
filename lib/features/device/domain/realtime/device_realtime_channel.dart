import 'package:remote_control_device/features/device/domain/realtime/device_realtime_client.dart';
import 'package:remote_control_device/features/signaling/domain/signaling_client.dart';

/// The one authenticated `/devices` socket, seen through both of its ports.
///
/// `REALTIME.md` gives a device a single socket that carries presence, the
/// server-to-device notices and the signaling relay at once. Two ports describe
/// it because two features consume it and neither should have to know about the
/// other's half; this interface exists only where that fact has to be stated —
/// the composition root, which builds one object and hands each feature the
/// port it needs.
///
/// No layer above the composition root depends on it. `DeviceRealtimeBloc`
/// takes a [DeviceRealtimeClient] and `SignalingBloc` takes a
/// [DeviceSignalingClient]; neither can reach the other's side of the socket.
abstract interface class DeviceRealtimeChannel
    implements DeviceRealtimeClient, DeviceSignalingClient {}
