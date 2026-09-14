import 'dart:async';

import 'package:remote_control_device/features/device/domain/realtime/device_realtime_channel.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
import 'package:remote_control_device/features/signaling/domain/entities/join_remote_session_result.dart';
import 'package:remote_control_device/features/signaling/domain/entities/remote_signaling_message.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_relay_result.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_answer.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_ice_candidate.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_offer.dart';

/// Stand-in for the Socket.IO client, in both of the roles the real one plays.
///
/// It exists so the blocs can be exercised without a socket, a backend or a
/// timer: tests decide exactly which signal arrives and when, can assert which
/// token each handshake would have carried, and can script what each signaling
/// ACK answers.
///
/// It implements [DeviceRealtimeChannel] rather than the two ports separately
/// for the same reason the production object does — there is one socket, and a
/// test where presence and signaling could disagree about whether it exists
/// would be testing a situation that cannot happen.
class FakeDeviceRealtimeClient implements DeviceRealtimeChannel {
  final StreamController<DeviceRealtimeSignal> _signals =
      StreamController<DeviceRealtimeSignal>.broadcast();
  final StreamController<RemoteSignalingMessage> _signalingMessages =
      StreamController<RemoteSignalingMessage>.broadcast();

  /// One entry per connection attempt, in order. The last one is the token the
  /// most recent handshake would have presented.
  final List<String> connectedWithTokens = [];

  int disconnectCount = 0;
  int disposeCount = 0;

  // ------------------------------------------------------------- signaling

  /// Session ids passed to [joinRemoteSession], in order. Length is how many
  /// joins were attempted, which is what the duplicate tests assert on.
  final List<String> joinedSessionIds = [];

  /// Outgoing relays, in order, as `(event, payload)` — the payload being the
  /// typed model, so a test can check the exact fields that would be sent.
  final List<WebRtcOffer> sentOffers = [];
  final List<WebRtcAnswer> sentAnswers = [];
  final List<WebRtcIceCandidate> sentIceCandidates = [];

  /// What the next join answers. Replaced per test; [joinQueue] wins when set.
  JoinRemoteSessionResult joinResult = const RemoteSessionJoined('');

  /// Answers scripted one join at a time, consumed before [joinResult]. Lets a
  /// test say "this join is refused, the next one succeeds".
  final List<JoinRemoteSessionResult> joinQueue = [];

  /// What every relay answers.
  SignalingRelayResult relayResult = const SignalingRelayDelivered('');

  /// When set, [joinRemoteSession] does not answer until the test completes it.
  /// The only way to observe the state *while* a join is in flight.
  Completer<void>? joinGate;

  @override
  Stream<DeviceRealtimeSignal> get signals => _signals.stream;

  @override
  Stream<RemoteSignalingMessage> get signalingMessages =>
      _signalingMessages.stream;

  @override
  void connect(String deviceToken) => connectedWithTokens.add(deviceToken);

  @override
  void disconnect() => disconnectCount++;

  @override
  Future<void> dispose() async {
    disposeCount++;
    if (!_signals.isClosed) await _signals.close();
    if (!_signalingMessages.isClosed) await _signalingMessages.close();
  }

  @override
  Future<JoinRemoteSessionResult> joinRemoteSession(
    String remoteSessionId,
  ) async {
    joinedSessionIds.add(remoteSessionId);
    await joinGate?.future;
    final scripted = joinQueue.isNotEmpty
        ? joinQueue.removeAt(0)
        : joinResult;
    // A bare `RemoteSessionJoined('')` in a test means "accepted": the real
    // transport echoes the id it was asked about, so the fake does too.
    return scripted is RemoteSessionJoined && scripted.remoteSessionId.isEmpty
        ? RemoteSessionJoined(remoteSessionId)
        : scripted;
  }

  @override
  Future<SignalingRelayResult> sendOffer(WebRtcOffer offer) async {
    sentOffers.add(offer);
    return _relayAnswerFor(offer.remoteSessionId);
  }

  @override
  Future<SignalingRelayResult> sendAnswer(WebRtcAnswer answer) async {
    sentAnswers.add(answer);
    return _relayAnswerFor(answer.remoteSessionId);
  }

  @override
  Future<SignalingRelayResult> sendIceCandidate(
    WebRtcIceCandidate candidate,
  ) async {
    sentIceCandidates.add(candidate);
    return _relayAnswerFor(candidate.remoteSessionId);
  }

  SignalingRelayResult _relayAnswerFor(String remoteSessionId) {
    final scripted = relayResult;
    return scripted is SignalingRelayDelivered &&
            scripted.remoteSessionId.isEmpty
        ? SignalingRelayDelivered(remoteSessionId)
        : scripted;
  }

  /// How many relays were attempted, of any kind.
  int get relayCount =>
      sentOffers.length + sentAnswers.length + sentIceCandidates.length;

  // ----------------------------------------------------------------- pumps

  /// Pushes a signal and lets the listening bloc process it before returning.
  Future<void> emit(DeviceRealtimeSignal signal) async {
    push(signal);
    await pump();
  }

  /// Pushes a signal without waiting. Widget tests need this: their fake-async
  /// zone only advances when the tester pumps, so awaiting a real delay there
  /// would never complete.
  void push(DeviceRealtimeSignal signal) => _signals.add(signal);

  /// Pushes a relayed `webrtc:*` as if the backend had just delivered it, and
  /// lets the listening bloc process it.
  Future<void> deliver(RemoteSignalingMessage message) async {
    _signalingMessages.add(message);
    await pump();
  }

  /// Drains the microtask queue so stream delivery and bloc event handling
  /// complete before the next assertion.
  static Future<void> pump() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }
}
