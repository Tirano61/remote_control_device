import 'dart:async';
import 'dart:developer' as developer;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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

part 'webrtc_session_event.dart';
part 'webrtc_session_state.dart';

/// The answering half of the peer connection with `remote_control_web`.
///
/// The role is fixed and everything else follows from it:
///
/// ```text
/// remote_control_web      offerer   creates the peer connection and the
///                                   "control" data channel, sends webrtc:offer
///
/// remote_control_device   answerer  waits, answers, receives the channel
/// ```
///
/// So this bloc has no path that creates an offer, and no path that creates a
/// data channel. A device that built either could end up negotiating against a
/// web app doing the same thing at the same moment, and glare resolution is a
/// problem better not to have: one offerer means there is never a collision to
/// resolve.
///
/// What starts a negotiation is one event, `webrtc:offer`, and only when all
/// three of these hold:
///
/// ```text
/// the socket is joined to a remote session's signaling room
/// the backend holds that session live (CONNECTING or ACTIVE)
/// the offer names that same session
/// ```
///
/// Not a connected socket, not a live session, not `peerJoined`. Readiness says
/// the technician is in the room; it does not say an offer is coming, and
/// building a peer connection on it would leave a connection with nothing to
/// apply — or, worse, tempt this side into offering.
///
/// Generations are the other structural idea here. A peer connection keeps
/// reporting state after the moment it was given up on, so every callback is
/// tagged with the generation that produced it and anything late is dropped.
/// Without it, a connection that failed while its replacement was being built
/// would tear the replacement down.
///
/// Finally, this bloc never touches the `RemoteSession`. The contract is
/// explicit that signaling changes no backend row, and the only path to
/// `ACTIVE` is the technician's `POST /remote-sessions/:id/activate` — so a
/// session reading `CONNECTING` while this reads [WebRtcConnected] is the
/// expected outcome for as long as that call takes, and not a discrepancy to
/// paper over. When the row does move, nothing here moves with it: `ACTIVE` is
/// a backend fact about a connection this bloc already holds, and renegotiating
/// on it would break the very connection it reports.
class WebRtcSessionBloc extends Bloc<WebRtcSessionEvent, WebRtcSessionState> {
  WebRtcSessionBloc({
    required WebRtcPeerConnectionFactory peerConnectionFactory,
    required WebRtcSignalingGateway signaling,
    required WebRtcIceConfiguration iceConfiguration,
  }) : _peerConnectionFactory = peerConnectionFactory,
       _signaling = signaling,
       _iceConfiguration = iceConfiguration,
       super(const WebRtcIdle()) {
    on<WebRtcOfferReceived>(_onOfferReceived);
    on<WebRtcRemoteIceReceived>(_onRemoteIceReceived);
    on<WebRtcSignalingAvailabilityChanged>(_onSignalingAvailabilityChanged);
    on<WebRtcRemoteSessionChanged>(_onRemoteSessionChanged);
    on<WebRtcLocalIceProduced>(_onLocalIceProduced);
    on<WebRtcConnectionStateChanged>(_onConnectionStateChanged);
    on<WebRtcDataChannelOffered>(_onDataChannelOffered);
    on<WebRtcDataChannelStateChanged>(_onDataChannelStateChanged);
  }

  static const String _loggerName = 'webrtc';

  final WebRtcPeerConnectionFactory _peerConnectionFactory;
  final WebRtcSignalingGateway _signaling;
  final WebRtcIceConfiguration _iceConfiguration;

  /// Bumped whenever a negotiation is abandoned or replaced. Everything a peer
  /// connection reports carries the generation it belongs to, and anything that
  /// does not match the current one is a message about a connection that no
  /// longer exists.
  int _generation = 0;

  WebRtcPeerConnection? _peer;
  WebRtcDataChannel? _controlChannel;

  final List<StreamSubscription<Object?>> _peerSubscriptions = [];
  final List<StreamSubscription<Object?>> _channelSubscriptions = [];

  /// The session the current negotiation belongs to. Set from the offer *after*
  /// the offer has been checked against the joined and live session, so it is
  /// never a session adopted from a payload.
  String? _negotiationSessionId;

  /// The SDP of the offer being negotiated, used only to tell a repeat of the
  /// same offer from a genuinely new one. Never logged and never sent back.
  String? _negotiatedOfferSdp;

  /// The last state the joined room and the backend session were seen in. Both
  /// are preconditions for accepting an offer and neither is a trigger.
  String? _joinedRemoteSessionId;
  String? _liveRemoteSessionId;

  bool _remoteDescriptionApplied = false;

  /// Whether `webrtc:answer` reached the technician's namespace.
  ///
  /// Local candidates wait for this. They are gathered from the moment the
  /// local description is set, which is before the answer has been relayed, and
  /// a candidate that arrives at a peer with no remote answer applied is a
  /// candidate for a negotiation the other end has not started.
  bool _answerDelivered = false;

  /// Local candidates produced before the answer was delivered, in the order
  /// ICE produced them.
  final List<PeerIceCandidate> _pendingLocalIce = [];

  /// Remote candidates that arrived before the offer had been applied.
  ///
  /// The web sends its candidates as soon as its offer is delivered and does
  /// not wait for the answer, so they routinely overtake
  /// `setRemoteDescription` on this side. Dropping them would leave the two
  /// ends trying to pair with half the addresses.
  final List<PeerIceCandidate> _pendingRemoteIce = [];

  bool _flushingLocalIce = false;
  bool _flushingRemoteIce = false;

  WebRtcDataChannelState? _controlChannelState;

  /// Frames received on the `control` channel, unparsed and un-acted-upon.
  ///
  /// Published so a silent channel can be told from a working one, and so the
  /// prompt that introduces the control protocol has somewhere to attach. This
  /// build executes nothing: no tap, no swipe, no Back, no Home, no text.
  final StreamController<WebRtcDataChannelMessage> _controlMessages =
      StreamController<WebRtcDataChannelMessage>.broadcast();

  Stream<WebRtcDataChannelMessage> get controlMessages =>
      _controlMessages.stream;

  // ----------------------------------------------------------------- offer

  Future<void> _onOfferReceived(
    WebRtcOfferReceived event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final offer = event.offer;
    final sessionId = offer.remoteSessionId;

    // `SignalingBloc` already filters by the joined session, and this checks it
    // again. Not redundancy for its own sake: creating a peer connection is the
    // point at which a mistake stops being a dropped message and becomes a
    // technician's browser talking to a tablet it was never assigned.
    if (_joinedRemoteSessionId == null) {
      _log('offer ignored: signaling is not joined to any session');
      return;
    }
    if (_joinedRemoteSessionId != sessionId) {
      _log('offer ignored: it names a session this device is not joined to');
      return;
    }
    // And the backend has to still hold the session live. A session the device
    // cannot confirm is live is one the backend would refuse to relay for.
    if (_liveRemoteSessionId != sessionId) {
      _log('offer ignored: there is no live remote session with that id');
      return;
    }

    final current = state;
    if (current is WebRtcConnected) {
      // A healthy peer connection is not replaced by an unexpected offer in
      // this build. Tearing one down on a duplicate or a stray relay would turn
      // a working assistance session into a broken one, and the web has no
      // reason to offer again while its own connection is up.
      _log('offer ignored: a peer connection is already connected');
      return;
    }
    if (current is WebRtcNegotiation &&
        current is! WebRtcFailed &&
        current is! WebRtcClosed &&
        current.remoteSessionId == sessionId &&
        _negotiatedOfferSdp == offer.sdp) {
      // The same offer twice: one peer connection, one answer. A second of
      // either would have the web applying two answers to one offer.
      _log('offer ignored: it repeats the offer being negotiated');
      return;
    }

    _log('offer received for $sessionId');

    // Everything that guards against a concurrent second offer is set here,
    // before the first await: a later event finds the state, the session and
    // the SDP already recorded and takes the branch above.
    _generation++;
    final generation = _generation;
    _negotiationSessionId = sessionId;
    _negotiatedOfferSdp = offer.sdp;
    emit(WebRtcPreparing(sessionId));

    // A previous negotiation — failed, closed, or superseded by this offer —
    // releases everything it held before a new one exists, so the two never
    // share a channel or a candidate queue.
    await _releasePeer();
    if (generation != _generation) return;

    WebRtcPeerConnection peer;
    try {
      peer = await _peerConnectionFactory.create(_iceConfiguration);
    } catch (_) {
      if (generation != _generation) return;
      _log('peer connection could not be created for $sessionId');
      emit(WebRtcFailed(sessionId));
      return;
    }
    if (generation != _generation) {
      // Abandoned while it was being built. It is closed rather than kept:
      // a peer connection nobody holds a reference to still holds native
      // resources and still gathers candidates.
      await peer.close();
      return;
    }

    _peer = peer;
    _bindPeer(peer, generation);

    try {
      await peer.setRemoteDescription(WebRtcSessionDescription.offer(offer.sdp));
      if (generation != _generation) return;
      _log('remote description applied for $sessionId');
      _remoteDescriptionApplied = true;

      // Anything that overtook the offer is applied now, in arrival order.
      await _flushRemoteIce(generation);
      if (generation != _generation) return;

      emit(WebRtcAnswering(sessionId, controlChannel: _controlChannelState));

      final answer = await peer.createAnswer();
      if (generation != _generation) return;
      _log('answer created for $sessionId');

      await peer.setLocalDescription(answer);
      if (generation != _generation) return;

      final relayed = await _signaling.sendAnswer(
        WebRtcAnswer(remoteSessionId: sessionId, sdp: answer.sdp),
      );
      if (generation != _generation) return;

      if (relayed is! SignalingRelayDelivered) {
        // The answer never reached the technician's namespace, so the web is
        // still waiting for one and this half-negotiated connection can only
        // hold resources. It is closed, once, and not retried: the same answer
        // would meet the same refusal. What recovers from here already exists —
        // the socket rejoins, the remote session is reconciled over REST, and
        // the web creates a new offer.
        _log('answer not relayed for $sessionId: ${_describe(relayed)}');
        await _teardownPeer();
        emit(WebRtcFailed(sessionId));
        return;
      }

      _log('answer relayed for $sessionId');
      _answerDelivered = true;
      emit(WebRtcConnecting(sessionId, controlChannel: _controlChannelState));

      // Deliberately not awaited: the flush keeps draining for as long as ICE
      // keeps producing candidates, which can be the whole life of the
      // connection, and an event handler is not a place to spend it.
      unawaited(_flushLocalIce(generation));
    } catch (_) {
      if (generation != _generation) return;
      // Nothing about the failure is printed. A libwebrtc error message can
      // quote the SDP it choked on.
      _log('negotiation failed for $sessionId');
      await _teardownPeer();
      emit(WebRtcFailed(sessionId));
    }
  }

  // ------------------------------------------------------------------- ICE

  Future<void> _onRemoteIceReceived(
    WebRtcRemoteIceReceived event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final candidate = event.candidate;
    if (_negotiationSessionId == null ||
        _negotiationSessionId != candidate.remoteSessionId) {
      _log('remote ICE candidate ignored: it names another session');
      return;
    }
    if (_peer == null) {
      // No negotiation to attach it to. Signaling is ephemeral by design and
      // nothing buffers it for a peer connection that may never be built.
      _log('remote ICE candidate ignored: there is no peer connection');
      return;
    }

    // Appended even when it could be applied straight away, so that the queue
    // is the single place arrival order is kept.
    _pendingRemoteIce.add(
      PeerIceCandidate(
        candidate: candidate.candidate,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex,
      ),
    );
    if (!_remoteDescriptionApplied) return;
    await _flushRemoteIce(_generation);
  }

  Future<void> _flushRemoteIce(int generation) async {
    if (_flushingRemoteIce) return;
    _flushingRemoteIce = true;
    try {
      while (_pendingRemoteIce.isNotEmpty) {
        if (generation != _generation) return;
        final peer = _peer;
        if (peer == null) return;

        final candidate = _pendingRemoteIce.removeAt(0);
        try {
          await peer.addRemoteIceCandidate(candidate);
        } catch (_) {
          // One candidate that could not be applied is not a failed
          // negotiation: ICE tries every pair it has. The line is never
          // printed, so only the fact is recorded.
          _log('a remote ICE candidate could not be applied');
        }
      }
    } finally {
      _flushingRemoteIce = false;
    }
  }

  Future<void> _onLocalIceProduced(
    WebRtcLocalIceProduced event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    if (event.generation != _generation) return;
    _pendingLocalIce.add(event.candidate);
    unawaited(_flushLocalIce(event.generation));
  }

  /// Sends queued local candidates in the order ICE produced them.
  ///
  /// Nothing leaves before the answer has been delivered, and only one send is
  /// ever in flight, which is what makes the order on the wire the order they
  /// were gathered in. New candidates appended while this is draining are
  /// picked up by the same loop rather than racing it.
  Future<void> _flushLocalIce(int generation) async {
    if (_flushingLocalIce) return;
    if (!_answerDelivered) return;

    final sessionId = _negotiationSessionId;
    if (sessionId == null) return;

    _flushingLocalIce = true;
    try {
      while (_pendingLocalIce.isNotEmpty) {
        if (generation != _generation) return;
        // This loop is deliberately not awaited by its caller, so it can still
        // be running while the application is shutting down. Relaying then
        // would reach a signaling bloc that is already closed.
        if (isClosed) return;

        final candidate = _pendingLocalIce.removeAt(0);
        final result = await _signaling.sendIceCandidate(
          WebRtcIceCandidate(
            remoteSessionId: sessionId,
            candidate: candidate.candidate,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex,
          ),
        );
        if (result is! SignalingRelayDelivered) {
          // Recorded and dropped. A candidate is one of many paths, not the
          // negotiation, so a refused relay never closes a connection — least
          // of all a connected one — and is never retried, because signaling is
          // ephemeral and a retry loop is how two ends flood each other.
          _log('local ICE candidate not relayed: ${_describe(result)}');
        }
      }
    } finally {
      _flushingLocalIce = false;
    }
  }

  // ---------------------------------------------------------- preconditions

  Future<void> _onSignalingAvailabilityChanged(
    WebRtcSignalingAvailabilityChanged event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    _joinedRemoteSessionId = event.remoteSessionId;
    if (event.remoteSessionId != null) return;

    // Signaling went away. What that costs depends entirely on whether the two
    // ends had already found each other:
    //
    //   still negotiating  the answer or the candidates cannot be sent, so the
    //                      negotiation cannot complete. It is closed, and the
    //                      device goes back to waiting for a new offer — which
    //                      the web will make after its own rejoin.
    //
    //   already connected  nothing. WebRTC is peer to peer; the socket only
    //                      introduced the two ends and is not in the path. A
    //                      teardown here would break a working connection for
    //                      no reason, and a renegotiation on reconnect would
    //                      break it a second time.
    switch (state) {
      case WebRtcPreparing() || WebRtcAnswering() || WebRtcConnecting():
        _log('negotiation abandoned: signaling is no longer joined');
        await _teardownPeer();
        _negotiationSessionId = null;
        emit(const WebRtcIdle());
      case WebRtcIdle() ||
          WebRtcConnected() ||
          WebRtcInterrupted() ||
          WebRtcFailed() ||
          WebRtcClosed():
        return;
    }
  }

  Future<void> _onRemoteSessionChanged(
    WebRtcRemoteSessionChanged event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final sessionId = event.remoteSessionId;
    if (sessionId == _liveRemoteSessionId) return;
    _liveRemoteSessionId = sessionId;

    // The assistance this peer connection belongs to is over, or it is a
    // different assistance now. Either way nothing of the old one may survive:
    // a peer connection that outlived its remote session would be a technician
    // still reaching the tablet after the backend says the session is closed.
    if (_negotiationSessionId == null) return;
    if (sessionId == _negotiationSessionId) return;

    _log('negotiation closed: the remote session it belonged to is gone');
    await _teardownPeer();
    _negotiationSessionId = null;
    emit(const WebRtcIdle());
  }

  // ------------------------------------------------------- peer connection

  Future<void> _onConnectionStateChanged(
    WebRtcConnectionStateChanged event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    if (event.generation != _generation) return;

    final sessionId = _negotiationSessionId;
    if (sessionId == null) return;

    switch (event.connectionState) {
      case WebRtcConnectionState.initial:
      case WebRtcConnectionState.connecting:
        // Only news on the way back from a connection that had been up. While
        // the negotiation is still being set up it says nothing the state does
        // not already say.
        if (state is WebRtcConnected || state is WebRtcInterrupted) {
          emit(
            WebRtcConnecting(sessionId, controlChannel: _controlChannelState),
          );
        }
      case WebRtcConnectionState.connected:
        _log('peer connection connected for $sessionId');
        emit(WebRtcConnected(sessionId, controlChannel: _controlChannelState));
      case WebRtcConnectionState.disconnected:
        // Possibly transient, which is what WebRTC means by it. Nothing is
        // closed and no timer is started: ICE may re-pair on its own, and a
        // deadline picked out of the air here would cut off recoveries that
        // were about to succeed.
        _log('peer connection interrupted for $sessionId');
        emit(
          WebRtcInterrupted(sessionId, controlChannel: _controlChannelState),
        );
      case WebRtcConnectionState.failed:
        _log('peer connection failed for $sessionId');
        await _teardownPeer();
        emit(WebRtcFailed(sessionId));
      case WebRtcConnectionState.closed:
        // Reaching here means the other end closed it — this side detaches its
        // callbacks before closing, so its own closes are never reported back.
        _log('peer connection closed for $sessionId');
        await _teardownPeer();
        emit(WebRtcClosed(sessionId));
    }
  }

  // ---------------------------------------------------------- data channel

  Future<void> _onDataChannelOffered(
    WebRtcDataChannelOffered event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final channel = event.channel;

    if (event.generation != _generation) {
      _log('data channel closed: it belongs to a previous negotiation');
      await channel.close();
      return;
    }
    if (channel.label != controlDataChannelLabel) {
      // The label is the whole contract with the web at this stage. A channel
      // with any other label is not something this build can interpret, and
      // leaving it open would mean holding a transport nothing reads.
      _log('data channel closed: unexpected label "${channel.label}"');
      await channel.close();
      return;
    }
    if (_controlChannel != null) {
      // One control channel per negotiation. The first valid one is kept: it is
      // the one whose state the rest of the application has been watching, and
      // swapping it for a later arrival would drop that history for no gain.
      _log('duplicate control data channel closed');
      await channel.close();
      return;
    }

    _log('control data channel received');
    _controlChannel = channel;
    _controlChannelState = channel.state;
    _channelSubscriptions.addAll([
      channel.states.listen(
        (channelState) =>
            add(WebRtcDataChannelStateChanged(event.generation, channelState)),
      ),
      // Read, never executed. There is no control protocol in this build.
      channel.messages.listen((message) {
        if (_controlMessages.isClosed) return;
        _controlMessages.add(message);
      }),
    ]);

    if (channel.state == WebRtcDataChannelState.open) {
      _log('control data channel open');
    }
    emit(_withControlChannel(channel.state));
  }

  Future<void> _onDataChannelStateChanged(
    WebRtcDataChannelStateChanged event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    if (event.generation != _generation) return;
    if (_controlChannel == null) return;

    _controlChannelState = event.channelState;
    if (event.channelState == WebRtcDataChannelState.open) {
      _log('control data channel open');
    }
    emit(_withControlChannel(event.channelState));
  }

  /// Rewrites the current state with a new channel state, leaving everything
  /// else alone. The channel and the connection move independently, so neither
  /// may overwrite the other's half of the state.
  WebRtcSessionState _withControlChannel(WebRtcDataChannelState? channelState) {
    final current = state;
    // One that has not started cannot have been given a channel.
    if (current is! WebRtcNegotiation) return current;

    final sessionId = current.remoteSessionId;
    return switch (current) {
      WebRtcPreparing() => WebRtcPreparing(
        sessionId,
        controlChannel: channelState,
      ),
      WebRtcAnswering() => WebRtcAnswering(
        sessionId,
        controlChannel: channelState,
      ),
      WebRtcConnecting() => WebRtcConnecting(
        sessionId,
        controlChannel: channelState,
      ),
      WebRtcConnected() => WebRtcConnected(
        sessionId,
        controlChannel: channelState,
      ),
      WebRtcInterrupted() => WebRtcInterrupted(
        sessionId,
        controlChannel: channelState,
      ),
      // A negotiation that is over carries no channel any more.
      WebRtcFailed() || WebRtcClosed() => current,
    };
  }

  // -------------------------------------------------------------- plumbing

  void _bindPeer(WebRtcPeerConnection peer, int generation) {
    _peerSubscriptions.addAll([
      peer.connectionStates.listen(
        (connectionState) =>
            add(WebRtcConnectionStateChanged(generation, connectionState)),
      ),
      peer.localIceCandidates.listen(
        (candidate) => add(WebRtcLocalIceProduced(generation, candidate)),
      ),
      peer.dataChannels.listen(
        (channel) => add(WebRtcDataChannelOffered(generation, channel)),
      ),
    ]);
  }

  /// Abandons the current negotiation and releases everything it held.
  ///
  /// The generation is bumped first, so anything the connection reports while
  /// it is being closed already belongs to a generation nobody is listening
  /// for.
  Future<void> _teardownPeer() async {
    _generation++;
    // Cleared here and not in [_releasePeer]: the offer being negotiated is
    // what tells a repeat of it from a new one, and the release that happens
    // *inside* the offer flow must not erase the marker the flow just set.
    _negotiatedOfferSdp = null;
    await _releasePeer();
  }

  /// Releases the peer connection, its channel, its subscriptions and its
  /// queues, without touching the generation.
  ///
  /// Idempotent, and it has to be: a failed transport, a closed remote session,
  /// a lost signaling room and a dropped credential all lead here and none of
  /// them can know whether it is first.
  Future<void> _releasePeer() async {
    final subscriptions = [..._peerSubscriptions, ..._channelSubscriptions];
    _peerSubscriptions.clear();
    _channelSubscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }

    final channel = _controlChannel;
    final peer = _peer;
    _controlChannel = null;
    _controlChannelState = null;
    _peer = null;

    _pendingLocalIce.clear();
    _pendingRemoteIce.clear();
    _remoteDescriptionApplied = false;
    _answerDelivered = false;

    await channel?.close();
    await peer?.close();
  }

  /// Names an outcome without printing anything the contract keeps out of logs.
  static String _describe(SignalingRelayResult result) => switch (result) {
    SignalingRelayDelivered() => 'delivered',
    SignalingRelayRefused(:final error) => 'refused (${error.name})',
    SignalingRelayUnanswered() => 'unanswered',
    SignalingRelayNotSent(:final reason) => 'not sent (${reason.name})',
  };

  /// Never an SDP, never a candidate line, never a token. Session ids are
  /// operational identifiers and are safe.
  void _log(String message) {
    if (kDebugMode) developer.log(message, name: _loggerName);
  }

  @override
  Future<void> close() async {
    await _teardownPeer();
    await _controlMessages.close();
    return super.close();
  }
}
