import 'dart:async';

import 'package:remote_control_device/features/signaling/domain/entities/signaling_relay_result.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_answer.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_ice_candidate.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_offer.dart';
import 'package:remote_control_device/features/webrtc/domain/control_channel.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/peer_ice_candidate.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_message.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_session_description.dart';
import 'package:remote_control_device/features/webrtc/domain/webrtc_peer_client.dart';
import 'package:remote_control_device/features/webrtc/domain/webrtc_signaling_gateway.dart';

import 'remote_session_fakes.dart';
import 'signaling_fakes.dart';

/// Stand-ins for everything on the far side of the WebRTC port.
///
/// WebRTC on Android is a native library: a unit test cannot start one, cannot
/// gather a real candidate and cannot connect two peers. That is exactly why
/// the port exists — the negotiation, the queues, the generations and the
/// channel rules are ordinary Dart and are tested here, while the real
/// `flutter_webrtc` adapter is verified where it can only be verified, with a
/// browser and a tablet.

/// A second SDP, so a genuinely new offer can never be mistaken for a repeat
/// of the one being negotiated.
const String testSecondOfferSdp = 'v=0\r\no=- 77777 2 IN IP4 127.0.0.1\r\n';

/// The answer this fake stack produces. Different from every offer fixture, so
/// a test that relayed the wrong SDP shows it.
const String testLocalAnswerSdp = 'v=0\r\no=- 11111 2 IN IP4 127.0.0.1\r\n';

WebRtcOffer offerFor({
  String remoteSessionId = testRemoteSessionId,
  String sdp = testSdp,
}) => WebRtcOffer(remoteSessionId: remoteSessionId, sdp: sdp);

WebRtcIceCandidate remoteCandidate({
  String remoteSessionId = testRemoteSessionId,
  String candidate = testIceCandidate,
  String? sdpMid = '0',
  int? sdpMLineIndex = 0,
}) => WebRtcIceCandidate(
  remoteSessionId: remoteSessionId,
  candidate: candidate,
  sdpMid: sdpMid,
  sdpMLineIndex: sdpMLineIndex,
);

PeerIceCandidate localCandidate(String line) =>
    PeerIceCandidate(candidate: line, sdpMid: '0', sdpMLineIndex: 0);

/// Hands out [FakeWebRtcPeerConnection]s and remembers every one of them, so a
/// test can assert that a second negotiation built a second connection — or
/// that a duplicate offer built none.
class FakeWebRtcPeerConnectionFactory implements WebRtcPeerConnectionFactory {
  final List<FakeWebRtcPeerConnection> created = [];

  /// The configurations each connection was asked for, in order.
  final List<WebRtcIceConfiguration> configurations = [];

  /// When true, the next [create] throws — a peer connection that could not be
  /// built at all.
  bool failNextCreate = false;

  /// When true, every connection handed out refuses the offer it is given. The
  /// flag lives here because the connection is created inside the negotiation,
  /// where a test has no chance to reach it first.
  bool failSetRemoteDescription = false;

  /// When set, [create] does not answer until the test completes it. The only
  /// way to observe what happens to an offer arriving mid-construction.
  Completer<void>? createGate;

  /// Applied to every connection handed out: `setRemoteDescription` does not
  /// return until the test completes it. Set here rather than on a connection
  /// because the connection is created inside the negotiation, which is over
  /// by the time a test could reach it.
  Completer<void>? setRemoteDescriptionGate;

  FakeWebRtcPeerConnection get last => created.last;
  int get createCount => created.length;

  @override
  Future<WebRtcPeerConnection> create(
    WebRtcIceConfiguration configuration,
  ) async {
    configurations.add(configuration);
    await createGate?.future;
    if (failNextCreate) {
      failNextCreate = false;
      throw StateError('peer connection could not be created');
    }
    final connection = FakeWebRtcPeerConnection()
      ..failSetRemoteDescription = failSetRemoteDescription
      ..setRemoteDescriptionGate = setRemoteDescriptionGate;
    created.add(connection);
    return connection;
  }
}

/// Records the negotiation in the order it happened and lets the test push
/// everything a real connection would report.
class FakeWebRtcPeerConnection implements WebRtcPeerConnection {
  /// Every call, in order, as a short name. This is what the offer-flow test
  /// asserts on: the order of `setRemoteDescription`, `createAnswer` and
  /// `setLocalDescription` is the negotiation, and getting it wrong produces a
  /// connection that never pairs.
  final List<String> calls = [];

  final List<WebRtcSessionDescription> remoteDescriptions = [];
  final List<WebRtcSessionDescription> localDescriptions = [];

  /// Remote candidates actually handed to the connection, in order.
  final List<PeerIceCandidate> addedRemoteCandidates = [];

  /// What [createAnswer] produces.
  WebRtcSessionDescription answer = const WebRtcSessionDescription.answer(
    testLocalAnswerSdp,
  );

  /// When true, [setRemoteDescription] throws.
  bool failSetRemoteDescription = false;

  /// When set, [setRemoteDescription] does not answer until completed, so a
  /// test can deliver ICE while the offer is still being applied.
  Completer<void>? setRemoteDescriptionGate;

  int closeCount = 0;
  bool get isClosed => closeCount > 0;

  final StreamController<WebRtcConnectionState> _connectionStates =
      StreamController<WebRtcConnectionState>.broadcast();
  final StreamController<PeerIceCandidate> _localIceCandidates =
      StreamController<PeerIceCandidate>.broadcast();
  final StreamController<WebRtcDataChannel> _dataChannels =
      StreamController<WebRtcDataChannel>.broadcast();

  @override
  Stream<WebRtcConnectionState> get connectionStates =>
      _connectionStates.stream;

  @override
  Stream<PeerIceCandidate> get localIceCandidates =>
      _localIceCandidates.stream;

  @override
  Stream<WebRtcDataChannel> get dataChannels => _dataChannels.stream;

  @override
  Future<void> setRemoteDescription(
    WebRtcSessionDescription description,
  ) async {
    calls.add('setRemoteDescription');
    remoteDescriptions.add(description);
    await setRemoteDescriptionGate?.future;
    if (failSetRemoteDescription) throw StateError('bad offer');
  }

  @override
  Future<WebRtcSessionDescription> createAnswer() async {
    calls.add('createAnswer');
    return answer;
  }

  @override
  Future<void> setLocalDescription(
    WebRtcSessionDescription description,
  ) async {
    calls.add('setLocalDescription');
    localDescriptions.add(description);
  }

  @override
  Future<void> addRemoteIceCandidate(PeerIceCandidate candidate) async {
    calls.add('addRemoteIceCandidate');
    addedRemoteCandidates.add(candidate);
  }

  @override
  Future<void> close() async {
    closeCount++;
    if (!_connectionStates.isClosed) await _connectionStates.close();
    if (!_localIceCandidates.isClosed) await _localIceCandidates.close();
    if (!_dataChannels.isClosed) await _dataChannels.close();
  }

  // ----------------------------------------------------------------- pushes

  /// Reports a connection state, as libwebrtc would.
  void pushConnectionState(WebRtcConnectionState state) {
    if (_connectionStates.isClosed) return;
    _connectionStates.add(state);
  }

  /// Reports a locally gathered candidate.
  void pushLocalCandidate(PeerIceCandidate candidate) {
    if (_localIceCandidates.isClosed) return;
    _localIceCandidates.add(candidate);
  }

  /// Reports a data channel opened by the peer.
  FakeWebRtcDataChannel pushDataChannel({
    String label = controlDataChannelLabel,
    WebRtcDataChannelState state = WebRtcDataChannelState.connecting,
  }) {
    final channel = FakeWebRtcDataChannel(label: label, initialState: state);
    if (!_dataChannels.isClosed) _dataChannels.add(channel);
    return channel;
  }
}

class FakeWebRtcDataChannel implements WebRtcDataChannel {
  FakeWebRtcDataChannel({
    required this.label,
    WebRtcDataChannelState initialState = WebRtcDataChannelState.connecting,
  }) : _state = initialState;

  @override
  final String label;

  @override
  bool get ordered => true;

  WebRtcDataChannelState _state;
  int closeCount = 0;
  bool get isClosed => closeCount > 0;

  final StreamController<WebRtcDataChannelState> _states =
      StreamController<WebRtcDataChannelState>.broadcast();
  final StreamController<WebRtcDataChannelMessage> _messages =
      StreamController<WebRtcDataChannelMessage>.broadcast();

  @override
  WebRtcDataChannelState get state => _state;

  @override
  Stream<WebRtcDataChannelState> get states => _states.stream;

  @override
  Stream<WebRtcDataChannelMessage> get messages => _messages.stream;

  @override
  Future<void> close() async {
    closeCount++;
    _state = WebRtcDataChannelState.closed;
    if (!_states.isClosed) await _states.close();
    if (!_messages.isClosed) await _messages.close();
  }

  void pushState(WebRtcDataChannelState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }

  void pushMessage(WebRtcDataChannelMessage message) {
    if (!_messages.isClosed) _messages.add(message);
  }
}

/// The signaling half, recording exactly what would go on the wire.
class FakeWebRtcSignalingGateway implements WebRtcSignalingGateway {
  final List<WebRtcAnswer> sentAnswers = [];
  final List<WebRtcIceCandidate> sentIceCandidates = [];

  /// What every answer relay returns. A `SignalingRelayDelivered('')` means
  /// "delivered", with the id filled in from the request.
  SignalingRelayResult answerResult = const SignalingRelayDelivered('');

  /// What every candidate relay returns.
  SignalingRelayResult candidateResult = const SignalingRelayDelivered('');

  /// When set, [sendAnswer] does not answer until the test completes it, so a
  /// test can gather local candidates while the answer is still in flight.
  Completer<void>? answerGate;

  @override
  Future<SignalingRelayResult> sendAnswer(WebRtcAnswer answer) async {
    sentAnswers.add(answer);
    await answerGate?.future;
    return _resultFor(answerResult, answer.remoteSessionId);
  }

  @override
  Future<SignalingRelayResult> sendIceCandidate(
    WebRtcIceCandidate candidate,
  ) async {
    sentIceCandidates.add(candidate);
    return _resultFor(candidateResult, candidate.remoteSessionId);
  }

  /// The candidate lines that were relayed, in order — which is the whole
  /// point of the ICE ordering tests.
  List<String> get sentIceLines => [
    for (final candidate in sentIceCandidates) candidate.candidate,
  ];

  static SignalingRelayResult _resultFor(
    SignalingRelayResult scripted,
    String remoteSessionId,
  ) =>
      scripted is SignalingRelayDelivered && scripted.remoteSessionId.isEmpty
      ? SignalingRelayDelivered(remoteSessionId)
      : scripted;
}
