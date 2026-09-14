import 'package:remote_control_device/features/signaling/domain/entities/join_remote_session_result.dart';
import 'package:remote_control_device/features/signaling/domain/entities/remote_signaling_message.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_relay_result.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_answer.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_ice_candidate.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_offer.dart';

/// Port to the signaling half of the `/devices` socket.
///
/// It is a second view of the *same* connection `DeviceRealtimeClient`
/// describes, not a second connection: `REALTIME.md` gives a device one
/// authenticated socket, and both presence and signaling ride on it. Splitting
/// the port in two is what keeps the signaling feature from depending on the
/// device feature's realtime signals, and the realtime feature from growing
/// knowledge of SDP.
///
/// Everything here is transport only. It joins, emits, parses and reports; it
/// decides nothing. Whether a join is due, whether a message may be sent and
/// what a refusal costs are questions answered a layer up, by `SignalingBloc`.
///
/// Nothing this port handles is ever persisted. The contract is explicit that
/// SDP and ICE are relayed and immediately forgotten, and the same holds on
/// this side: no offer, answer, candidate or joined flag ever reaches secure
/// storage, `SharedPreferences` or a database.
abstract interface class DeviceSignalingClient {
  /// Every `webrtc:*` that arrived with a payload matching the contract.
  ///
  /// Broadcast, and unfiltered: a message for a session this client is not
  /// joined to still appears here. Filtering by the joined session is a
  /// decision, and decisions live above the transport.
  Stream<RemoteSignalingMessage> get signalingMessages;

  /// Emits `remote-session:join` and waits for its `JoinRemoteSessionAck`.
  ///
  /// Answers [RemoteSessionJoinUnanswered] rather than queueing when there is
  /// no live socket: Socket.IO would otherwise buffer the packet and send it on
  /// the next connection, which is exactly the stale join this client must
  /// never make.
  Future<JoinRemoteSessionResult> joinRemoteSession(String remoteSessionId);

  /// Emits `webrtc:offer` and waits for its `SignalingRelayAck`.
  Future<SignalingRelayResult> sendOffer(WebRtcOffer offer);

  /// Emits `webrtc:answer` and waits for its `SignalingRelayAck`.
  Future<SignalingRelayResult> sendAnswer(WebRtcAnswer answer);

  /// Emits `webrtc:ice-candidate` and waits for its `SignalingRelayAck`.
  Future<SignalingRelayResult> sendIceCandidate(WebRtcIceCandidate candidate);
}
