import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:remote_control_device/features/webrtc/domain/entities/peer_ice_candidate.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_message.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_session_description.dart';
import 'package:remote_control_device/features/webrtc/domain/webrtc_peer_client.dart';

/// The only place in the application that knows `flutter_webrtc` exists.
///
/// Its whole job is translation: callbacks become streams, enums become this
/// project's enums, and the two shapes libwebrtc insists on — an SDP type
/// spelled as a string, an end-of-candidates spelled as an empty line — are
/// absorbed here so that nothing above has to know them.
///
/// It decides nothing. It never chooses when to create a connection, never
/// picks which data channel to keep, never retries and never gives up; every
/// one of those is a decision and lives in `WebRtcSessionBloc`.
///
/// Nothing here logs an SDP or a candidate line. The states it does log are
/// operational facts that carry no address and no secret.
class FlutterWebRtcPeerConnectionFactory implements WebRtcPeerConnectionFactory {
  const FlutterWebRtcPeerConnectionFactory();

  @override
  Future<WebRtcPeerConnection> create(
    WebRtcIceConfiguration configuration,
  ) async {
    final connection = await rtc.createPeerConnection(<String, dynamic>{
      'iceServers': [
        for (final server in configuration.iceServers)
          <String, dynamic>{'urls': server.urls},
      ],
      // Unified Plan is the only semantics current libwebrtc supports, and
      // naming it keeps this end from depending on a default that has changed
      // before. `remote_control_web` negotiates with the same semantics.
      'sdpSemantics': 'unified-plan',
    });
    return _FlutterWebRtcPeerConnection(connection);
  }
}

class _FlutterWebRtcPeerConnection implements WebRtcPeerConnection {
  _FlutterWebRtcPeerConnection(this._connection) {
    _connection.onConnectionState = (state) {
      final mapped = _connectionStateOf(state);
      _log('peer connection ${mapped.name}');
      if (!_connectionStates.isClosed) _connectionStates.add(mapped);
    };
    _connection.onIceCandidate = (candidate) {
      final mapped = _candidateOf(candidate);
      if (!_localIceCandidates.isClosed) _localIceCandidates.add(mapped);
    };
    _connection.onDataChannel = (channel) {
      // The label is a value the peer chose. It is logged because deciding what
      // to do with an unexpected channel is impossible to diagnose otherwise,
      // and because a label carries nothing sensitive.
      _log('data channel received: ${channel.label}');
      if (_dataChannels.isClosed) return;
      _dataChannels.add(_FlutterWebRtcDataChannel(channel));
    };
  }

  static const String _loggerName = 'webrtc';

  final rtc.RTCPeerConnection _connection;

  final StreamController<WebRtcConnectionState> _connectionStates =
      StreamController<WebRtcConnectionState>.broadcast();
  final StreamController<PeerIceCandidate> _localIceCandidates =
      StreamController<PeerIceCandidate>.broadcast();
  final StreamController<WebRtcDataChannel> _dataChannels =
      StreamController<WebRtcDataChannel>.broadcast();

  bool _closed = false;

  @override
  Stream<WebRtcConnectionState> get connectionStates => _connectionStates.stream;

  @override
  Stream<PeerIceCandidate> get localIceCandidates => _localIceCandidates.stream;

  @override
  Stream<WebRtcDataChannel> get dataChannels => _dataChannels.stream;

  @override
  Future<void> setRemoteDescription(WebRtcSessionDescription description) =>
      _connection.setRemoteDescription(_descriptionOf(description));

  @override
  Future<WebRtcSessionDescription> createAnswer() async {
    final answer = await _connection.createAnswer();
    // libwebrtc types both fields as nullable although an answer it produced
    // always carries them. Refusing an unusable one here is better than
    // relaying an empty SDP the backend would reject as INVALID_PAYLOAD.
    final sdp = answer.sdp;
    if (sdp == null || sdp.isEmpty) {
      throw StateError('createAnswer produced no SDP');
    }
    return WebRtcSessionDescription.answer(sdp);
  }

  @override
  Future<void> setLocalDescription(WebRtcSessionDescription description) =>
      _connection.setLocalDescription(_descriptionOf(description));

  /// End-of-candidates is where the two vocabularies differ.
  ///
  /// The signaling contract allows an empty `candidate` and says some
  /// implementations use it to mean "that was the last one". libwebrtc has no
  /// use for it: gathering completion is carried by the remote description and
  /// by its own gathering state, and handing the Android bridge a candidate
  /// with an empty line is at best ignored and at worst a native exception.
  ///
  /// So it is consumed here, which is exactly the encapsulation the port
  /// promises: the bloc relays whatever the peer sent without knowing that this
  /// particular value stops at the boundary.
  @override
  Future<void> addRemoteIceCandidate(PeerIceCandidate candidate) async {
    if (candidate.isEndOfCandidates) {
      _log('remote end-of-candidates');
      return;
    }
    await _connection.addCandidate(
      rtc.RTCIceCandidate(
        candidate.candidate,
        candidate.sdpMid,
        candidate.sdpMLineIndex,
      ),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    // Detached first, so the teardown below cannot come back as a state change
    // for a connection nobody is watching any more.
    _connection.onConnectionState = null;
    _connection.onIceCandidate = null;
    _connection.onDataChannel = null;

    try {
      await _connection.close();
    } catch (_) {
      // A connection that is already gone natively is the outcome asked for.
    }
    try {
      await _connection.dispose();
    } catch (_) {
      // Same: closing must never throw, because every teardown path calls it
      // and none of them has anything left to do about a failure.
    }

    if (!_connectionStates.isClosed) await _connectionStates.close();
    if (!_localIceCandidates.isClosed) await _localIceCandidates.close();
    if (!_dataChannels.isClosed) await _dataChannels.close();
  }

  static rtc.RTCSessionDescription _descriptionOf(
    WebRtcSessionDescription description,
  ) => rtc.RTCSessionDescription(description.sdp, switch (description.kind) {
    WebRtcSdpKind.offer => 'offer',
    WebRtcSdpKind.answer => 'answer',
  });

  static PeerIceCandidate _candidateOf(rtc.RTCIceCandidate candidate) =>
      PeerIceCandidate(
        // Normalised, not invented: libwebrtc types the line as nullable and a
        // null one means end-of-candidates, which the contract spells as the
        // empty string. The line itself is never touched otherwise.
        candidate: candidate.candidate ?? '',
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex,
      );

  static WebRtcConnectionState _connectionStateOf(
    rtc.RTCPeerConnectionState state,
  ) => switch (state) {
    rtc.RTCPeerConnectionState.RTCPeerConnectionStateNew =>
      WebRtcConnectionState.initial,
    rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnecting =>
      WebRtcConnectionState.connecting,
    rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
      WebRtcConnectionState.connected,
    rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
      WebRtcConnectionState.disconnected,
    rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
      WebRtcConnectionState.failed,
    rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed =>
      WebRtcConnectionState.closed,
  };

  static void _log(String message) {
    if (kDebugMode) developer.log(message, name: _loggerName);
  }
}

class _FlutterWebRtcDataChannel implements WebRtcDataChannel {
  _FlutterWebRtcDataChannel(this._channel) {
    _state = _stateOf(_channel.state);
    _channel.onDataChannelState = (state) {
      final mapped = _stateOf(state);
      _state = mapped;
      if (!_states.isClosed) _states.add(mapped);
    };
    _channel.onMessage = (message) {
      if (_messages.isClosed) return;
      _messages.add(
        message.isBinary
            ? WebRtcDataChannelMessage.binary(message.binary)
            : WebRtcDataChannelMessage.text(message.text),
      );
    };
  }

  final rtc.RTCDataChannel _channel;

  final StreamController<WebRtcDataChannelState> _states =
      StreamController<WebRtcDataChannelState>.broadcast();
  final StreamController<WebRtcDataChannelMessage> _messages =
      StreamController<WebRtcDataChannelMessage>.broadcast();

  late WebRtcDataChannelState _state;
  bool _closed = false;

  /// libwebrtc types the label as nullable. A channel without one cannot be the
  /// `control` channel, and an empty string is refused by the same comparison
  /// that refuses any other unexpected label.
  @override
  String get label => _channel.label ?? '';

  /// Not carried by `RTCDataChannel` on the receiving side: the peer's
  /// `RTCDataChannelInit` is not relayed to the answerer. `remote_control_web`
  /// creates the channel ordered, and this build refuses no channel over it, so
  /// the honest answer is the documented expectation rather than a read value.
  @override
  bool get ordered => true;

  @override
  WebRtcDataChannelState get state => _state;

  @override
  Stream<WebRtcDataChannelState> get states => _states.stream;

  @override
  Stream<WebRtcDataChannelMessage> get messages => _messages.stream;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    _channel.onDataChannelState = null;
    _channel.onMessage = null;
    try {
      await _channel.close();
    } catch (_) {
      // Already closed natively, which is the outcome asked for.
    }
    _state = WebRtcDataChannelState.closed;

    if (!_states.isClosed) await _states.close();
    if (!_messages.isClosed) await _messages.close();
  }

  static WebRtcDataChannelState _stateOf(rtc.RTCDataChannelState? state) =>
      switch (state) {
        rtc.RTCDataChannelState.RTCDataChannelConnecting =>
          WebRtcDataChannelState.connecting,
        rtc.RTCDataChannelState.RTCDataChannelOpen =>
          WebRtcDataChannelState.open,
        rtc.RTCDataChannelState.RTCDataChannelClosing =>
          WebRtcDataChannelState.closing,
        rtc.RTCDataChannelState.RTCDataChannelClosed ||
        null => WebRtcDataChannelState.closed,
      };
}
