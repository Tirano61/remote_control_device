import 'dart:async';
import 'dart:developer' as developer;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/core/async/timer_factory.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_inbound_message.dart';
import 'package:remote_control_device/features/device/domain/realtime/heartbeat_evidence.dart';
import 'package:remote_control_device/features/device/domain/realtime/realtime_liveness.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_command_queue.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_touch_controller.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_relay_result.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_answer.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_ice_candidate.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_offer.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_capture_result.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_capture_status.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_transmission.dart';
import 'package:remote_control_device/features/screen_capture/domain/screen_capture_client.dart';
import 'package:remote_control_device/features/webrtc/domain/control_channel.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/peer_ice_candidate.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/sdp_origin.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/screen_video_attachment.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_connection_state.dart';
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
///
/// `ACTIVE` does decide one thing here: whether a control command is obeyed. A
/// gesture only runs with all of this true at the moment it is received:
///
/// ```text
/// the command came from the current generation's control channel
/// that channel is open
/// the backend holds this negotiation's session ACTIVE
/// ```
///
/// The accessibility service being enabled is not on that list. It stays enabled
/// between assistances, so it says nothing about whether the user has authorised
/// anyone today.
///
/// The screen has a gate of its own, separate from the capture: frames reach the
/// technician only while
///
/// ```text
/// the capture belongs to the live remote session
/// the tablet can confirm that session's authority right now
/// Android has not taken the screen away in it
/// ```
///
/// Losing any of them keeps every new frame on the tablet at once, while
/// MediaProjection and its consent stay for the recovery; see
/// [_syncScreenTransmission].
///
/// And an opening of that gate only lasts as long as the `/devices` heartbeat
/// vouches for it: it is given the newest heartbeat evidence and renewed with
/// every PING that continues the chain, and the Android side holds every frame
/// back the moment that evidence is too old — by itself, whether or not this
/// isolate is running. A lease found run out there counts as an overdue
/// heartbeat: the gate stays shut until the authority is confirmed again; see
/// [_onScreenLeaseLapsed].
class WebRtcSessionBloc extends Bloc<WebRtcSessionEvent, WebRtcSessionState> {
  WebRtcSessionBloc({
    required WebRtcPeerConnectionFactory peerConnectionFactory,
    required WebRtcSignalingGateway signaling,
    required WebRtcIceConfiguration iceConfiguration,
    required ScreenCaptureClient screenCapture,
    required RemoteControlAccessibilityClient remoteControl,
    Duration orphanCaptureTimeout = defaultOrphanCaptureTimeout,
    TimerFactory timerFactory = systemTimerFactory,
    RealtimeLiveness? channelLiveness,
    HeartbeatEvidenceSource? transmissionEvidence,
  }) : _peerConnectionFactory = peerConnectionFactory,
       _signaling = signaling,
       _iceConfiguration = iceConfiguration,
       _screenCapture = screenCapture,
       _remoteControl = remoteControl,
       _orphanCaptureTimeout = orphanCaptureTimeout,
       _timerFactory = timerFactory,
       _channelLiveness = channelLiveness,
       _transmissionEvidence = transmissionEvidence,
       super(const WebRtcIdle()) {
    on<WebRtcScreenCaptureEndedByPlatform>(_onScreenCaptureEndedByPlatform);
    on<_WebRtcOrphanCaptureExpired>(_onOrphanCaptureExpired);
    on<_WebRtcScreenTransmissionFailed>(_onScreenTransmissionFailed);
    on<_WebRtcHeartbeatEvidence>(_onHeartbeatEvidence);
    on<_WebRtcScreenLeaseLapsed>(_onScreenLeaseLapsed);
    _evidenceSubscription = transmissionEvidence?.evidence.listen(
      (evidence) => add(_WebRtcHeartbeatEvidence(evidence)),
    );
    _platformStopSubscription = _screenCapture.endedByPlatform.listen(
      (remoteSessionId) =>
          add(WebRtcScreenCaptureEndedByPlatform(remoteSessionId)),
    );
    on<WebRtcOfferReceived>(_onOfferReceived);
    on<WebRtcRemoteIceReceived>(_onRemoteIceReceived);
    on<WebRtcSignalingAvailabilityChanged>(_onSignalingAvailabilityChanged);
    on<WebRtcRemoteSessionChanged>(_onRemoteSessionChanged);
    on<WebRtcActiveRemoteSessionChanged>(_onActiveRemoteSessionChanged);
    on<WebRtcRemoteSessionAuthorityChanged>(_onAuthorityChanged);
    on<WebRtcLocalIceProduced>(_onLocalIceProduced);
    on<WebRtcConnectionStateChanged>(_onConnectionStateChanged);
    on<WebRtcDataChannelOffered>(_onDataChannelOffered);
    on<WebRtcDataChannelStateChanged>(_onDataChannelStateChanged);
    on<WebRtcControlMessageReceived>(_onControlMessageReceived);
  }

  /// How long a running screen capture may wait, *inside its session's
  /// signaling room*, for a peer connection to carry it again — after the one
  /// that carried it FAILED, was CLOSED by the other end, or was abandoned
  /// while negotiating — before it is stopped.
  ///
  /// Within the window a new offer for the same live session reuses the
  /// capture without asking the user again, which is what a technician whose
  /// browser recovers needs. After it, nobody is receiving the screen and
  /// nobody has said they will: MediaProjection is stopped, and a later offer
  /// goes through Android's dialog again.
  ///
  /// The window only runs while a recovery offer could actually reach this
  /// device — while it is joined to the room of the capture's session. Out of
  /// the room (the socket is down, or back but the session not yet confirmed)
  /// no offer can arrive, so none is being waited for: the window is cancelled
  /// and starts again, in full, when the device rejoins. That time out of the
  /// room is bounded elsewhere — by the authority grace (75 s, after which the
  /// tablet ends the session and the capture with it) and by the backend's
  /// disconnect grace (60 s, after which it closes the session as SYSTEM).
  /// Nothing is transmitted meanwhile: there is no peer to transmit to, and
  /// the transmission gate is closed while the authority is suspended.
  ///
  /// Until Prompt 41 it was 20 s counted from the peer's failure, wherever the
  /// device was. On the T10A a 5 s Wi-Fi cut (scenario B) lost the capture
  /// that way although the recovery was authorised: the web's first recovery
  /// offer left while the tablet was still out of the room and was lost, the
  /// web only tries again once its own answer deadline (30 s) and the next
  /// step of its schedule (5 s) have passed — 32 s after the tablet was back
  /// in the room — and the window had run out at 20 s. 45 s covers that
  /// second attempt: 30 s + 5 s + a REST read and the relay of the offer,
  /// with margin.
  static const Duration defaultOrphanCaptureTimeout = Duration(seconds: 45);

  static const String _loggerName = 'webrtc';

  final WebRtcPeerConnectionFactory _peerConnectionFactory;
  final WebRtcSignalingGateway _signaling;
  final WebRtcIceConfiguration _iceConfiguration;
  final ScreenCaptureClient _screenCapture;
  final RemoteControlAccessibilityClient _remoteControl;
  final Duration _orphanCaptureTimeout;
  final TimerFactory _timerFactory;

  /// Checked right before a command is let through, on top of the session's
  /// confirmed authority; see [_isChannelFresh]. `null` (tests of this bloc
  /// alone) checks nothing more.
  final RealtimeLiveness? _channelLiveness;

  /// Where an opening of the screen's gate gets its lease from, and what keeps
  /// it renewed; see [_syncScreenTransmission]. `null` (tests of this bloc
  /// alone) opens with no lease; in the application it is never `null`, and
  /// the Android side never transmits without one.
  final HeartbeatEvidenceSource? _transmissionEvidence;
  StreamSubscription<HeartbeatEvidence>? _evidenceSubscription;

  /// Whether the native gate found the running opening's lease run out. Until
  /// the session's confirmed authority moves (it is suspended, or confirmed
  /// for another session) nothing reopens the gate: not a PING, not a renewal.
  bool _screenLeaseLapsed = false;

  /// Moves on every opening, so that the answer about an older one is told
  /// from the one that holds.
  int _transmissionEpoch = 0;

  late final StreamSubscription<String> _platformStopSubscription;

  /// The generation whose peer connection the running capture is attached to,
  /// or `null`. A capture with no current peer attached to it has no receiver.
  int? _captureAttachedGeneration;

  /// Stops a capture left without a receiver; see [defaultOrphanCaptureTimeout].
  Timer? _orphanCaptureTimer;

  /// The remote session for which Android stopped the screen capture by itself
  /// (MediaProjection `onStop`), or `null`.
  ///
  /// Control in that session is withdrawn for good, its peer connection is
  /// closed and no new offer for it is answered: the user (or the system) took
  /// the screen away, and neither a renegotiation nor a silent new capture is
  /// how that is undone. A different session, with its own consent, clears it.
  String? _screenRevokedSessionId;

  /// The remote touch, if any. Its `touch_hold` waits in [_commandQueue] like
  /// any command; what follows it comes here directly. Every path that drops
  /// the queue's pending commands ends it first.
  late final RemoteTouchController _touches = RemoteTouchController(
    _remoteControl,
    log: _log,
  );

  late final RemoteControlCommandQueue _commandQueue =
      RemoteControlCommandQueue(_remoteControl, touches: _touches);

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
  ///
  /// Also the marker of a negotiation that still holds — or is building — a
  /// peer connection: set when an offer is accepted, cleared by every teardown.
  /// An offer arriving while it is set is a *replacement*, and goes through
  /// the recovery rule.
  String? _negotiatedOfferSdp;

  /// The `RTCPeerConnection` identities (see [SdpOrigin]) this device has
  /// accepted an offer from in [_offerOriginsSessionId], oldest first.
  ///
  /// An offer from one of them is never answered again: it is a repeat, a
  /// stale relay of a connection already replaced, or a renegotiation this
  /// build does not do. Bounded, and emptied when the live session changes.
  final Set<String> _acceptedOfferOrigins = <String>{};
  String? _offerOriginsSessionId;
  static const int _maxRememberedOfferOrigins = 32;

  /// The live session whose authority is confirmed right now, or `null`. Only
  /// read when an offer would replace an existing peer connection.
  String? _confirmedRemoteSessionId;

  /// Remote candidates beyond this many, waiting for an offer to be applied,
  /// are dropped. A browser trickles a handful; anything past this is not a
  /// negotiation.
  static const int _maxPendingRemoteIce = 128;

  /// The last state the joined room and the backend session were seen in. Both
  /// are preconditions for accepting an offer and neither is a trigger.
  String? _joinedRemoteSessionId;
  String? _liveRemoteSessionId;

  /// The session a control command may run in, or `null`. Narrower than
  /// [_liveRemoteSessionId]: `CONNECTING` is live, and it is not this.
  String? _activeRemoteSessionId;

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

  /// The generation whose flush loop is running, or `null`. Per generation and
  /// not a plain flag: a loop of a replaced peer may still be awaiting its last
  /// send when the new peer needs to start draining, and it must not hold the
  /// new one off. The old loop leaves at its next generation check without
  /// taking anything from the queue.
  int? _flushingLocalIceGeneration;
  int? _flushingRemoteIceGeneration;

  WebRtcDataChannelState? _controlChannelState;

  /// Where screen sharing is, as the rest of the application reads it. Kept
  /// beside [_controlChannelState] because both are facts the state carries
  /// and neither may overwrite the other's half of it.
  ScreenCaptureStatus _screenCaptureStatus = ScreenCaptureStatus.idle;

  /// The remote session a running capture belongs to, or `null`.
  ///
  /// Held here and not read back from the client because it answers a question
  /// the client cannot: *may this capture outlive what just happened?* A peer
  /// connection being replaced leaves it alone; the backend's live session
  /// changing ends it. Those are two different lifetimes and this is the field
  /// that keeps them apart.
  String? _screenCaptureSessionId;

  /// The remote session a capture is being *requested* for — the Android
  /// dialog may be open, or the service still starting — or `null`. Lets an
  /// assistance that ends meanwhile abandon the request instead of finding a
  /// capture running for it later.
  String? _screenCaptureRequestId;

  /// Whether frames of the running capture may reach the technician, as last
  /// asked of the capture client. `false` whenever no capture runs: a new one
  /// starts with nothing transmitted. See [_syncScreenTransmission].
  bool _screenTransmissionAllowed = false;

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
    if (_screenRevokedSessionId == sessionId) {
      // Android took the screen away in this session. Answering would rebuild
      // a peer the user has just cut, and ask for the screen again unbidden.
      _log('offer ignored: Android stopped the screen capture in $sessionId');
      return;
    }

    // Which web `RTCPeerConnection` made this offer. Without it a new offer
    // cannot be told from a stale one, and none is answered.
    final origin = SdpOrigin.tryParse(offer.sdp);
    if (origin == null) {
      _log('offer ignored: its SDP has no readable origin');
      return;
    }
    if (_offerOriginsSessionId != sessionId) {
      _acceptedOfferOrigins.clear();
      _offerOriginsSessionId = sessionId;
    }
    if (_acceptedOfferOrigins.contains(origin.identity)) {
      // An offer from a connection this device already answered:
      //
      //   the same SDP       a repeat; one peer connection, one answer. A
      //                      second answer would reach a web that is no longer
      //                      waiting for one.
      //   anything else      a stale relay of a connection the web has since
      //                      replaced, or a renegotiation of one — which the
      //                      web never does: it builds a new connection.
      //
      // Neither replaces what this device holds now.
      _log(
        offer.sdp == _negotiatedOfferSdp
            ? 'offer ignored: it repeats the offer being negotiated'
            : 'offer ignored: it comes from a peer connection already '
                  'answered in this session',
      );
      return;
    }

    // An offer while a negotiation still holds, or is building, a peer
    // connection is a recovery: the web gave up on its connection and built a
    // new one, and this side may not have noticed yet — a dead web peer can
    // read CONNECTED here for tens of seconds. It replaces the old one only
    // with the session's authority confirmed right now; suspended, the old
    // peer stays as it is, under the suspension rules.
    final replacing = _negotiatedOfferSdp != null;
    if (replacing && _confirmedRemoteSessionId != sessionId) {
      _log(
        'recovery offer refused for $sessionId: its authority is not '
        'confirmed',
      );
      return;
    }

    // Recorded before anything else, so a later relay of this same offer —
    // even one handled while this is still awaiting — is a repeat.
    if (_acceptedOfferOrigins.length >= _maxRememberedOfferOrigins) {
      _acceptedOfferOrigins.remove(_acceptedOfferOrigins.first);
    }
    _acceptedOfferOrigins.add(origin.identity);

    if (replacing) {
      _log(
        'recovery offer accepted for $sessionId: replacing generation '
        '$_generation',
      );
    } else {
      _log('offer received for $sessionId');
    }

    // Everything that guards against a concurrent second offer is set here,
    // before the first await: a later event finds the session, the SDP and the
    // origin already recorded.
    //
    // And everything the old peer could still do is withdrawn here too, in
    // this order and synchronously, before a new peer exists:
    //
    //   1. generation   the old peer's channel, acks, ICE and state reports
    //                   are all dropped from this line on
    //   2. queue        a remote touch is abandoned — never released where the
    //                   finger happened to be — and queued commands refused
    //   3. remote ICE   whatever was waiting belonged to the old offer;
    //                   candidates arriving from now on are for this one
    //
    // Closing the old channel and the old connection follows, awaited, before
    // the new connection is built. There are never two peers, and a command is
    // obeyed on the new one only through the usual gate: its own open channel,
    // an ACTIVE session and confirmed authority, at the moment it arrives.
    _generation++;
    final generation = _generation;
    _commandQueue.discardPending();
    _pendingRemoteIce.clear();
    _remoteDescriptionApplied = false;
    _negotiationSessionId = sessionId;
    _negotiatedOfferSdp = offer.sdp;
    emit(WebRtcPreparing(sessionId, screenCapture: _screenCaptureStatus));

    // A previous negotiation — failed, closed, or superseded by this offer —
    // releases everything it held before a new one exists, so the two never
    // share a channel or a candidate queue. The remote candidates already
    // queued for *this* offer are kept.
    await _releasePeer(keepRemoteIce: true);
    if (generation != _generation) return;

    WebRtcPeerConnection peer;
    try {
      peer = await _peerConnectionFactory.create(_iceConfiguration);
    } catch (_) {
      if (generation != _generation) return;
      _log('peer connection could not be created for $sessionId');
      emit(WebRtcFailed(sessionId, screenCapture: _screenCaptureStatus));
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
      await peer.setRemoteDescription(
        WebRtcSessionDescription.offer(offer.sdp),
      );
      if (generation != _generation) return;
      _log('remote description applied for $sessionId');
      _remoteDescriptionApplied = true;

      // Anything that overtook the offer is applied now, in arrival order.
      await _flushRemoteIce(generation);
      if (generation != _generation) return;

      emit(_restate(WebRtcAnswering(sessionId)));

      // The screen goes on the connection *before* the answer is created, and
      // that is the whole ordering change this stage brings:
      //
      //   setRemoteDescription  the offer's m=video exists as a transceiver
      //   attach                that transceiver becomes sendonly, with track
      //   createAnswer          the SDP is written from what is now true
      //
      // The other way round would produce an answer describing a video section
      // this end is not sending on, and a second negotiation would be needed
      // to correct it. The user is asked for their screen inside this step, so
      // it can take as long as a person takes.
      await _prepareScreenCapture(sessionId, peer, generation, emit);
      if (generation != _generation) return;
      if (isClosed) return;

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
        emit(WebRtcFailed(sessionId, screenCapture: _screenCaptureStatus));
        return;
      }

      _log('answer relayed for $sessionId');
      _answerDelivered = true;
      emit(_restate(WebRtcConnecting(sessionId)));

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
      emit(WebRtcFailed(sessionId, screenCapture: _screenCaptureStatus));
    }
  }

  // --------------------------------------------------------- screen capture

  /// Asks for the screen and puts it on the offered video section.
  ///
  /// Returns having done everything it could and nothing it could not; it does
  /// not report success, because there is nothing for the caller to do
  /// differently. Whatever happens here — the user declines, the foreground
  /// service is refused, the capture fails, the offer carried no video —
  /// the answer is still created and the `control` channel still opens. The
  /// screen is an extra capability and losing it never costs the assistance.
  Future<void> _prepareScreenCapture(
    String sessionId,
    WebRtcPeerConnection peer,
    int generation,
    Emitter<WebRtcSessionState> emit,
  ) async {
    // A capture already running for this session is handed straight back by
    // the client, with no Android dialog: only a genuinely new one is worth
    // telling the user we are waiting for.
    if (!_screenCapture.isActive) {
      _screenCaptureStatus = ScreenCaptureStatus.requesting;
      emit(_restate());
    }

    _screenCaptureRequestId = sessionId;
    final ScreenCaptureResult result;
    try {
      result = await _screenCapture.requestAndStart(sessionId);
    } finally {
      if (_screenCaptureRequestId == sessionId) _screenCaptureRequestId = null;
    }

    if (_liveRemoteSessionId != sessionId) {
      // The assistance ended while the user was answering the Android dialog
      // or while the capture was starting — FINALIZAR, a close by the
      // technician, a dropped identity. A screen granted for a session that is
      // no longer live is not shared with anyone: it is stopped on the spot,
      // and nothing here records it as running. A refusal or a failure is not
      // recorded either: there is no assistance left for it to describe.
      if (result is ScreenCaptureStarted) {
        _log(
          'screen capture stopped: its remote session ended while it '
          'was starting',
        );
        await _stopScreenCapture();
      }
      if (!isClosed) emit(_restate());
      return;
    }

    switch (result) {
      case ScreenCaptureStarted(:final videoTrack):
        // Recorded before the generation is checked. Whatever happens to this
        // negotiation, a capture is running now and something has to know
        // which remote session it belongs to.
        _screenCaptureSessionId = sessionId;
        _screenCaptureStatus = ScreenCaptureStatus.active;
        // Decided now, from what is true now — not from what was true when the
        // offer arrived, which may be a person's dialog ago. A new capture
        // transmits nothing until this says so; a reused one is told again.
        _syncScreenTransmission(capturedAnew: true);

        if (generation != _generation) {
          // The negotiation was replaced while the user was answering the
          // Android dialog. The capture is deliberately *not* stopped: it
          // belongs to the remote session, the next peer connection for that
          // same session reuses it, and asking the user a second time for a
          // screen they just granted is the behaviour Android 14 made
          // expensive and users find alarming.
          _log('screen capture kept: its negotiation was replaced');
          break;
        }

        final attachment = await peer.attachScreenVideo(videoTrack);
        if (generation != _generation) {
          _log('screen capture kept: its negotiation was replaced');
          break;
        }
        switch (attachment) {
          case ScreenVideoAttachment.attached:
            _captureAttachedGeneration = generation;
            _log('video track attached');
          case ScreenVideoAttachment.noVideoTransceiver:
          case ScreenVideoAttachment.failed:
            // There is nowhere for the screen to go. Leaving MediaProjection
            // running would mean capturing a person's screen for nobody,
            // behind a notification telling them it is being shared — so it is
            // stopped, the failure is recorded, and the negotiation carries on
            // with the data channel alone.
            _log('screen capture stopped: it could not be attached');
            await _stopScreenCapture();
            _screenCaptureStatus = ScreenCaptureStatus.failed;
        }
      case ScreenCaptureDenied():
        _screenCaptureStatus = ScreenCaptureStatus.denied;
      case ScreenCaptureUnavailable():
        _screenCaptureStatus = ScreenCaptureStatus.failed;
    }

    if (!isClosed) emit(_restate());
  }

  /// Ends the capture and takes the notification down. Idempotent.
  ///
  /// Never called because a peer connection went away — only because the
  /// remote session it belonged to did, or because the application is closing.
  Future<bool> _stopScreenCapture() async {
    final wasRunning =
        _screenCaptureSessionId != null ||
        _screenCaptureStatus != ScreenCaptureStatus.idle;

    _screenCaptureSessionId = null;
    _captureAttachedGeneration = null;
    _screenCaptureStatus = ScreenCaptureStatus.idle;
    _screenTransmissionAllowed = false;
    _screenLeaseLapsed = false;
    try {
      await _screenCapture.stop();
    } catch (_) {
      // Teardown must never throw: several paths lead here and none of them
      // has anything left to do about a failure.
    }
    return wasRunning;
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
    if (_negotiatedOfferSdp == null) {
      // No negotiation to attach it to. Signaling is ephemeral by design and
      // nothing buffers it for a peer connection that may never be built.
      //
      // A negotiation whose peer is still being built *does* take it: the web
      // trickles its first candidates — host ones, the likeliest to pair —
      // right after its offer, and on a recovery they arrive while the old
      // peer is still being closed.
      _log('remote ICE candidate ignored: there is no peer connection');
      return;
    }
    if (_pendingRemoteIce.length >= _maxPendingRemoteIce) {
      _log('remote ICE candidate ignored: too many are waiting');
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
    if (generation != _generation) return;
    if (_flushingRemoteIceGeneration == generation) return;
    _flushingRemoteIceGeneration = generation;
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
      if (_flushingRemoteIceGeneration == generation) {
        _flushingRemoteIceGeneration = null;
      }
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
    if (generation != _generation) return;
    if (_flushingLocalIceGeneration == generation) return;
    if (!_answerDelivered) return;

    final sessionId = _negotiationSessionId;
    if (sessionId == null) return;

    _flushingLocalIceGeneration = generation;
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
      if (_flushingLocalIceGeneration == generation) {
        _flushingLocalIceGeneration = null;
      }
    }
  }

  // ---------------------------------------------------------- preconditions

  Future<void> _onSignalingAvailabilityChanged(
    WebRtcSignalingAvailabilityChanged event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    _joinedRemoteSessionId = event.remoteSessionId;
    // Joining or leaving the room moves the orphan window whether or not the
    // state changes below.
    _syncOrphanCaptureTimer();
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
        // The peer connection goes; the capture stays. Losing the signaling
        // room says nothing about the assistance — the backend still holds the
        // remote session — and the web will offer again after its own rejoin,
        // to a device that can answer with the screen it already has.
        _log('negotiation abandoned: signaling is no longer joined');
        await _teardownPeer();
        _negotiationSessionId = null;
        emit(WebRtcIdle(screenCapture: _screenCaptureStatus));
      case WebRtcIdle() ||
          WebRtcConnected() ||
          WebRtcInterrupted() ||
          WebRtcFailed() ||
          WebRtcClosed():
        return;
    }
  }

  /// The assistance ended — by either end, by a closed event, by the user of
  /// this tablet before the backend confirmed it, or by a device identity that
  /// is no longer valid — or it is a different assistance now. All of them
  /// arrive as this one event with a different id or with none, and all of
  /// them are taken down in the same order:
  ///
  /// ```text
  /// 1. control     no command is obeyed and a remote touch is let go
  ///                (synchronous: nothing is awaited before it)
  /// 2. peer        the data channel and the peer connection are closed
  /// 3. screen      MediaProjection is stopped, including one still starting
  /// ```
  ///
  /// The order is the order of what a technician could still do: act on the
  /// tablet, receive its screen, and only then nothing.
  Future<void> _onRemoteSessionChanged(
    WebRtcRemoteSessionChanged event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final sessionId = event.remoteSessionId;
    if (sessionId == _liveRemoteSessionId) return;
    _liveRemoteSessionId = sessionId;
    // A session that is no longer live cannot be the confirmed one either.
    if (_confirmedRemoteSessionId != sessionId) {
      _confirmedRemoteSessionId = null;
    }
    if (_offerOriginsSessionId != sessionId) {
      _acceptedOfferOrigins.clear();
      _offerOriginsSessionId = null;
    }

    // A screen Android took away belongs to the session it was taken from. The
    // next assistance starts clean, with its own Android dialog.
    var screenLineReset = false;
    if (_screenRevokedSessionId != null &&
        _screenRevokedSessionId != sessionId) {
      _screenRevokedSessionId = null;
      if (_screenCaptureStatus == ScreenCaptureStatus.stoppedBySystem) {
        _screenCaptureStatus = ScreenCaptureStatus.idle;
        screenLineReset = true;
      }
    }

    // 1. A session that is no longer live cannot be the active one, whatever
    // order the coordinator's events arrive in. Withdrawn before the first
    // await, so no command queued behind this event can slip through.
    if (_activeRemoteSessionId != null && _activeRemoteSessionId != sessionId) {
      _activeRemoteSessionId = null;
    }
    if (!_isControlAuthorized) _commandQueue.discardPending();
    // And the screen stops reaching anyone, before the peer and the capture
    // are taken down.
    _syncScreenTransmission();

    // 2. The assistance this peer connection belongs to is over, or it is a
    // different assistance now. Either way nothing of the old one may survive:
    // a peer connection that outlived its remote session would be a technician
    // still reaching the tablet after the session ended.
    final peerGone =
        _negotiationSessionId != null && sessionId != _negotiationSessionId;
    if (peerGone) {
      _log('negotiation closed: the remote session it belonged to is gone');
      await _teardownPeer();
      _negotiationSessionId = null;
    }

    // 3. The screen is released here and nowhere else. `MediaProjection`
    // belongs to the remote session: it survives a peer connection being
    // rebuilt, and it must not survive the assistance ending. A capture still
    // being started for the session that ended is abandoned too — the client
    // drops it at its next step — rather than being left to finish for nobody.
    var released = false;
    final captureSession = _screenCaptureSessionId ?? _screenCaptureRequestId;
    if (captureSession != null && captureSession != sessionId) {
      _log('screen capture stopped: its remote session is gone');
      released = await _stopScreenCapture();
    }

    if (isClosed) return;
    if (peerGone) {
      emit(WebRtcIdle(screenCapture: _screenCaptureStatus));
    } else if (released || screenLineReset) {
      // Nothing was torn down, but the screen line on the panel has just
      // changed and the state is the only way it hears about it.
      emit(_restate());
    }
  }

  Future<void> _onActiveRemoteSessionChanged(
    WebRtcActiveRemoteSessionChanged event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    _activeRemoteSessionId = event.remoteSessionId;
    if (!_isControlAuthorized) _commandQueue.discardPending();
  }

  /// Decides whether the screen is transmitted, and nothing else. Losing it
  /// does not touch a negotiation already under way — a recovery that was
  /// accepted has already closed the old peer, and the new one is held exactly
  /// as the old one would have been: kept through the suspension's grace
  /// period, obeying nothing, sending no frame, and taken down with the session
  /// if the grace runs out. That is RemoteSessionBloc's decision, and it
  /// reaches here as the live session going away.
  ///
  /// Synchronous on purpose: the frames are held back from the moment the
  /// event is handled, before anything else is awaited.
  Future<void> _onAuthorityChanged(
    WebRtcRemoteSessionAuthorityChanged event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    // A lapse is over once the authority it happened under is: suspended, or
    // confirmed again by a REST read made after the heartbeat came back.
    if (event.remoteSessionId != _confirmedRemoteSessionId) {
      _screenLeaseLapsed = false;
    }
    _confirmedRemoteSessionId = event.remoteSessionId;
    _syncScreenTransmission();
  }

  bool get _isControlAuthorized =>
      _activeRemoteSessionId != null &&
      _activeRemoteSessionId == _negotiationSessionId &&
      _negotiationSessionId != _screenRevokedSessionId;

  // ------------------------------------------------------ screen transmission

  /// Whether the running capture's frames may reach the technician right now.
  ///
  /// Read from the session the *capture* belongs to, not from a peer
  /// connection: the gate sits on the Android side between MediaProjection and
  /// the encoder, so it holds for every sender the track is on — the current
  /// peer, one being replaced, one still CONNECTED that the web gave up on.
  /// `CONNECTING` counts as well as `ACTIVE`: the technician sees the screen
  /// before activating, as always, but only with the session confirmed.
  bool get _mayTransmitScreen {
    final sessionId = _screenCaptureSessionId;
    return sessionId != null &&
        sessionId == _liveRemoteSessionId &&
        sessionId == _confirmedRemoteSessionId &&
        sessionId != _screenRevokedSessionId &&
        !_screenLeaseLapsed;
  }

  /// Brings the capture's transmission in line with [_mayTransmitScreen].
  ///
  /// Called synchronously from every handler that moves one of its inputs, and
  /// it decides from the current fields alone. So a late callback — a read, an
  /// offer, an answer, a peer's state — can never reopen it: it would need the
  /// authority confirmed, which only the coordinator sets. Revocation always
  /// wins because nothing else can open it.
  ///
  /// The client call is not awaited, and does not need to be: calls reach the
  /// platform in the order they are made, so the last one made is the one that
  /// holds. [capturedAnew] sends the decision even when it has not changed,
  /// for a capture that has just been started or handed back.
  void _syncScreenTransmission({bool capturedAnew = false}) {
    final sessionId = _screenCaptureSessionId;
    if (sessionId == null) {
      _screenTransmissionAllowed = false;
      return;
    }
    // An opening needs evidence to give its lease. Without any — no watched
    // connection right now — it waits for the next PING (see
    // [_onHeartbeatEvidence]); it never opens without one.
    final source = _transmissionEvidence;
    final evidence = source?.currentEvidence;
    final authorised = _mayTransmitScreen;
    final allowed = authorised && (source == null || evidence != null);
    if (allowed == _screenTransmissionAllowed && !capturedAnew) return;
    if (allowed != _screenTransmissionAllowed) {
      _log(
        allowed
            ? 'screen transmission resumed for $sessionId'
            : authorised
            ? 'screen transmission waits for $sessionId: no heartbeat evidence'
            : 'screen transmission suspended for $sessionId: its authority is '
                  'not confirmed',
      );
    }
    if (allowed && !_screenTransmissionAllowed) _transmissionEpoch++;
    _screenTransmissionAllowed = allowed;
    final epoch = _transmissionEpoch;
    unawaited(
      _screenCapture
          .setTransmitting(
            allowed,
            evidence: allowed && evidence != null
                ? _screenEvidenceOf(evidence)
                : null,
          )
          .then((outcome) {
            if (isClosed) return;
            switch (outcome) {
              case ScreenTransmissionOutcome.applied:
                return;
              case ScreenTransmissionOutcome.failed:
                add(_WebRtcScreenTransmissionFailed(sessionId));
              case ScreenTransmissionOutcome.lapsed:
                if (allowed) {
                  add(
                    _WebRtcScreenLeaseLapsed(
                      sessionId,
                      epoch: epoch,
                      evidence: evidence,
                    ),
                  );
                }
            }
          }),
    );
  }

  /// A PING continued the heartbeat chain: the running opening's lease is
  /// renewed with it. It renews; it never opens what the authority closed.
  ///
  /// The one opening it can cause is one that was only waiting for evidence —
  /// the authority confirmed, nothing suspended, no lapse — and that is the
  /// same decision [_syncScreenTransmission] makes from the same fields.
  Future<void> _onHeartbeatEvidence(
    _WebRtcHeartbeatEvidence event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final sessionId = _screenCaptureSessionId;
    if (sessionId == null) return;
    if (!_screenTransmissionAllowed) {
      if (_mayTransmitScreen) _syncScreenTransmission();
      return;
    }
    final epoch = _transmissionEpoch;
    final evidence = event.evidence;
    unawaited(
      _screenCapture.renewTransmission(_screenEvidenceOf(evidence)).then((
        renewal,
      ) {
        if (renewal == ScreenTransmissionRenewal.lapsed && !isClosed) {
          add(
            _WebRtcScreenLeaseLapsed(
              sessionId,
              epoch: epoch,
              evidence: evidence,
            ),
          );
        }
      }),
    );
  }

  /// The Android side holds the running opening's frames back: its lease ran
  /// out before evidence arrived, or the evidence it was given was already too
  /// old. The heartbeat stopped vouching for the authority, whatever this
  /// isolate's timers say, and it is handled as an overdue heartbeat would be:
  ///
  /// ```text
  /// 1. the gate is closed here too, and nothing reopens it while the session's
  ///    confirmed authority is the one this happened under
  /// 2. the watchdog is told; unless it already knows of the break, it declares
  ///    the heartbeat overdue, and the coordinators suspend the session
  /// 3. the next opening, a new grant, comes after a REST read made once the
  ///    heartbeat is back has confirmed the session again
  /// ```
  ///
  /// An answer about an older opening than the one that holds is ignored.
  Future<void> _onScreenLeaseLapsed(
    _WebRtcScreenLeaseLapsed event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final sessionId = event.remoteSessionId;
    if (sessionId != _screenCaptureSessionId ||
        event.epoch != _transmissionEpoch ||
        !_screenTransmissionAllowed) {
      return;
    }
    _log(
      'screen transmission lapsed for $sessionId: the heartbeat evidence ran '
      'out on the Android side; held back until its authority is confirmed '
      'again',
    );
    _screenLeaseLapsed = true;
    _syncScreenTransmission();
    final evidence = event.evidence;
    if (evidence != null) {
      _transmissionEvidence?.reportLapse(
        watch: evidence.watch,
        observedAtNanos: evidence.observedAtNanos,
      );
    }
  }

  static ScreenTransmissionEvidence _screenEvidenceOf(
    HeartbeatEvidence evidence,
  ) => ScreenTransmissionEvidence(
    channel: evidence.watch,
    observedAtNanos: evidence.observedAtNanos,
    validFor: evidence.validFor,
  );

  /// The platform could not hold the frames back, or let them through; the
  /// client has stopped the capture rather than leave it in doubt. Recorded as
  /// a failed screen. The assistance carries on without it, as it does when
  /// the capture cannot start.
  Future<void> _onScreenTransmissionFailed(
    _WebRtcScreenTransmissionFailed event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    if (_screenCaptureSessionId != event.remoteSessionId) return;
    _log('screen capture stopped: its transmission could not be changed');
    await _stopScreenCapture();
    _screenCaptureStatus = ScreenCaptureStatus.failed;
    if (!isClosed) emit(_restate());
  }

  // ----------------------------------------------------- screen withdrawn

  /// Android stopped the capture by itself: the user pressed *Stop sharing* in
  /// the system controls, or another projection took over.
  ///
  /// The screen was the condition the technician was working under, so what
  /// depended on it goes in the same order as every other withdrawal:
  ///
  /// ```text
  /// 1. control   withdrawn for this session; a remote touch abandoned and
  ///              queued commands dropped, before anything is awaited
  /// 2. peer      the data channel and the peer connection are closed
  /// 3. screen    already released by the client; recorded as stopped by the
  ///              system, never restarted from here
  /// ```
  ///
  /// The remote session itself is not closed: that is the user's FINALIZAR, or
  /// the technician's. Offers for it are no longer answered.
  Future<void> _onScreenCaptureEndedByPlatform(
    WebRtcScreenCaptureEndedByPlatform event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final sessionId = event.remoteSessionId;
    if (sessionId != _screenCaptureSessionId) {
      // A capture this bloc had already let go of, or one for another session.
      _log('platform stop ignored: it is not the capture in use');
      return;
    }

    _screenRevokedSessionId = sessionId;
    _commandQueue.discardPending();
    _screenCaptureSessionId = null;
    _captureAttachedGeneration = null;
    _screenTransmissionAllowed = false;
    _screenLeaseLapsed = false;
    _screenCaptureStatus = ScreenCaptureStatus.stoppedBySystem;
    _log('screen capture stopped by Android for $sessionId: control withdrawn');
    // Said before anything is awaited: nothing may go on reading "sharing".
    emit(_restate());

    if (_negotiationSessionId == sessionId) {
      await _teardownPeer();
      _negotiationSessionId = null;
      _log('negotiation closed: Android stopped its screen capture');
    }
    if (!isClosed) emit(WebRtcIdle(screenCapture: _screenCaptureStatus));
  }

  // ---------------------------------------------------------- orphan screen

  /// Whether the running capture is attached to the current peer connection.
  bool get _captureHasReceiver =>
      _peer != null && _captureAttachedGeneration == _generation;

  /// Starts or cancels the orphan-capture deadline after every state change.
  @override
  void onChange(Change<WebRtcSessionState> change) {
    super.onChange(change);
    _syncOrphanCaptureTimer();
  }

  /// Whether a recovery offer for the running capture's session could reach
  /// this device right now: it is joined to that session's signaling room.
  bool get _inCaptureSessionRoom {
    final sessionId = _screenCaptureSessionId;
    return sessionId != null && _joinedRemoteSessionId == sessionId;
  }

  /// Runs the orphan window exactly while the capture has no receiver *and*
  /// a new one could be offered — see [defaultOrphanCaptureTimeout]. Called
  /// after every state change and whenever the room membership changes, which
  /// does not always change the state.
  void _syncOrphanCaptureTimer() {
    final sessionId = _screenCaptureSessionId;
    if (sessionId == null || _captureHasReceiver) {
      _orphanCaptureTimer?.cancel();
      _orphanCaptureTimer = null;
      return;
    }
    if (!_inCaptureSessionRoom) {
      if (_orphanCaptureTimer != null) {
        _log(
          'screen capture has no receiver and no offer can reach this device '
          'out of the room: its window starts again on the rejoin',
        );
        _orphanCaptureTimer!.cancel();
        _orphanCaptureTimer = null;
      }
      return;
    }
    if (_orphanCaptureTimer != null) return;
    _log(
      'screen capture has no receiver: stopping it in '
      '${_orphanCaptureTimeout.inSeconds} s unless a new peer takes it',
    );
    _orphanCaptureTimer = _timerFactory(_orphanCaptureTimeout, () {
      _orphanCaptureTimer = null;
      if (!isClosed) add(_WebRtcOrphanCaptureExpired(sessionId));
    });
  }

  Future<void> _onOrphanCaptureExpired(
    _WebRtcOrphanCaptureExpired event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    if (_screenCaptureSessionId != event.remoteSessionId) return;
    if (_captureHasReceiver) return;
    _log('screen capture stopped: no peer connection took it in time');
    await _stopScreenCapture();
    if (!isClosed) emit(_restate());
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
          emit(_restate(WebRtcConnecting(sessionId)));
        }
      case WebRtcConnectionState.connected:
        _log('peer connection connected for $sessionId');
        emit(_restate(WebRtcConnected(sessionId)));
      case WebRtcConnectionState.disconnected:
        // Possibly transient, which is what WebRTC means by it. Nothing is
        // closed and no timer is started: ICE may re-pair on its own, and a
        // deadline picked out of the air here would cut off recoveries that
        // were about to succeed.
        _log('peer connection interrupted for $sessionId');
        emit(_restate(WebRtcInterrupted(sessionId)));
      case WebRtcConnectionState.failed:
        _log('peer connection failed for $sessionId');
        await _teardownPeer();
        emit(WebRtcFailed(sessionId, screenCapture: _screenCaptureStatus));
      case WebRtcConnectionState.closed:
        // Reaching here means the other end closed it — this side detaches its
        // callbacks before closing, so its own closes are never reported back.
        _log('peer connection closed for $sessionId');
        await _teardownPeer();
        emit(WebRtcClosed(sessionId, screenCapture: _screenCaptureStatus));
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
      channel.controlMessages.listen(
        (message) =>
            add(WebRtcControlMessageReceived(event.generation, message)),
      ),
    ]);

    if (channel.state == WebRtcDataChannelState.open) {
      _log('control data channel open');
    }
    emit(_restate());
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
    } else {
      _commandQueue.discardPending();
    }
    emit(_restate());
  }

  // ---------------------------------------------------------- remote control

  /// Decides what becomes of a frame from the `control` channel.
  ///
  /// Nothing awaits between the checks and [RemoteControlCommandQueue.submit],
  /// so what was checked is still true when the command is queued. From then on
  /// anything that ends the authorisation discards the queue.
  Future<void> _onControlMessageReceived(
    WebRtcControlMessageReceived event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final generation = event.generation;
    if (generation != _generation) {
      _log('control message dropped: it belongs to a previous negotiation');
      return;
    }
    final channel = _controlChannel;
    if (channel == null) return;

    switch (event.message) {
      case RemoteControlMessageRejected(:final id, :final error):
        _log('control command rejected: $id (${error.name})');
        _sendControlAck(
          generation,
          channel,
          RemoteControlAck.failure(id, error),
        );

      case RemoteControlCommandReceived(
        command: final RemoteTouchCommand command,
      ):
        _onTouchCommand(generation, channel, command);

      case RemoteControlCommandReceived(:final command):
        final (name, finished) = switch (command) {
          RemoteTapCommand() => ('tap', 'completed'),
          RemoteLongPressCommand() => ('long_press', 'completed'),
          RemoteSwipeCommand() => ('swipe', 'completed'),
          // Android says it took these, and never when they end.
          RemoteBackCommand() => ('back', 'accepted by android'),
          RemoteHomeCommand() => ('home', 'accepted by android'),
          RemoteRecentsCommand() => ('recents', 'accepted by android'),
          // The id and never the text, here and in every line below.
          RemoteSetTextCommand() => ('set_text', 'accepted by android'),
          RemoteImeEnterCommand() => ('ime_enter', 'accepted by android'),
          // Taken by the case above.
          RemoteTouchCommand() => ('touch', 'ended'),
        };
        _log('control command received: $name ${command.id}');

        if (channel.state != WebRtcDataChannelState.open) {
          _log('$name rejected: the control channel is not open');
          return;
        }
        if (!_isControlAuthorized || !_isChannelFresh(name)) {
          _log('$name rejected: the remote session is not active');
          _sendControlAck(
            generation,
            channel,
            RemoteControlAck.failure(
              command.id,
              RemoteControlError.sessionNotActive,
            ),
          );
          return;
        }

        _log('$name accepted');
        _commandQueue.submit(command, (ack) {
          _log(
            ack.ok
                ? '$name $finished ${ack.id}'
                : '$name rejected ${ack.id} (${ack.error?.name})',
          );
          _sendControlAck(generation, channel, ack);
        });
    }
  }

  /// Whether the `/devices` heartbeat still vouches for the authority this
  /// command would run under.
  ///
  /// The authority itself is withdrawn through the coordinators a few
  /// event-loop turns after the heartbeat goes overdue; and after the tablet
  /// slept or its isolate stalled, the watchdog's own timer may not have run
  /// yet. A command arriving in either gap is refused here, from the clock,
  /// and the watchdog's declaration follows on its own (see
  /// [RealtimeLiveness.confirmFresh]). The suspension that follows abandons a
  /// touch that is down, as any suspension does.
  ///
  /// It grants nothing: it is only asked once [_isControlAuthorized] holds.
  bool _isChannelFresh(String name) {
    final liveness = _channelLiveness;
    if (liveness == null || liveness.confirmFresh()) return true;
    _log('$name refused: the realtime heartbeat is overdue');
    return false;
  }

  /// A message of a remote touch, through the same gate as every command.
  ///
  /// The hold is registered with the touch controller, bound to this session,
  /// this generation and this channel, and queued: it is the only one that
  /// waits its turn. A move, a release or a cancel goes to the controller,
  /// which takes it only for the touch running under that same binding.
  ///
  /// Moves are not logged one by one: there may be thirty a second.
  void _onTouchCommand(
    int generation,
    WebRtcDataChannel channel,
    RemoteTouchCommand command,
  ) {
    final name = switch (command) {
      RemoteTouchHoldCommand() => 'touch_hold',
      RemoteTouchMoveCommand() => 'touch_move',
      RemoteTouchReleaseCommand() => 'touch_release',
      RemoteTouchCancelCommand() => 'touch_cancel',
    };
    if (command is! RemoteTouchMoveCommand) {
      _log('control command received: $name ${command.id}');
    }

    void answer(RemoteControlAck ack) {
      if (!ack.ok) _log('$name rejected ${ack.id} (${ack.error?.name})');
      _sendControlAck(generation, channel, ack);
    }

    if (channel.state != WebRtcDataChannelState.open) {
      _log('$name rejected: the control channel is not open');
      return;
    }
    if (!_isControlAuthorized || !_isChannelFresh(name)) {
      answer(
        RemoteControlAck.failure(
          command.id,
          RemoteControlError.sessionNotActive,
        ),
      );
      return;
    }

    final binding = RemoteTouchBinding(
      remoteSessionId: _negotiationSessionId!,
      generation: generation,
      channel: channel,
    );
    switch (command) {
      case RemoteTouchHoldCommand():
        final onHoldAck = _touches.register(command, binding, (ack) {
          _log(
            ack.ok
                ? 'touch_hold held ${ack.id}'
                : 'touch_hold rejected ${ack.id} (${ack.error?.name})',
          );
          _sendControlAck(generation, channel, ack);
        });
        if (onHoldAck == null) {
          // One finger: a second hold does not touch the one that is down.
          answer(
            RemoteControlAck.failure(
              command.id,
              RemoteControlError.gestureRejected,
            ),
          );
          return;
        }
        _commandQueue.submit(command, onHoldAck);
      case RemoteTouchMoveCommand():
        _touches.move(command, binding, answer);
      case RemoteTouchReleaseCommand():
        _touches.release(command, binding, (ack) {
          if (ack.ok) _log('touch_release completed ${ack.id}');
          answer(ack);
        });
      case RemoteTouchCancelCommand():
        _touches.cancel(command, binding, answer);
    }
  }

  /// Sends [ack] on the channel its command arrived on, if that is still the
  /// channel in use and it is still open. An ack can settle long after the
  /// command that caused it, and by then the channel may be closed or replaced.
  void _sendControlAck(
    int generation,
    WebRtcDataChannel channel,
    RemoteControlAck ack,
  ) {
    if (generation != _generation ||
        !identical(channel, _controlChannel) ||
        channel.state != WebRtcDataChannelState.open) {
      _log('control ack dropped: its channel is gone');
      return;
    }
    unawaited(channel.sendControlAck(ack));
  }

  /// Stamps the two facts the bloc tracks beside the negotiation — the
  /// `control` channel's state and where screen sharing is — onto a state.
  ///
  /// With [next] it is a transition: the negotiation moves and carries the
  /// other two along unchanged. Without it, it rewrites the current state in
  /// place, which is what a channel opening or a capture starting is — neither
  /// of those moves the negotiation, and neither may overwrite the other's
  /// half of the state.
  WebRtcSessionState _restate([WebRtcSessionState? next]) {
    final current = next ?? state;
    // A state with no negotiation carries no channel; it does carry the
    // capture, because MediaProjection outlives the peer connection.
    if (current is! WebRtcNegotiation) {
      return WebRtcIdle(screenCapture: _screenCaptureStatus);
    }

    final sessionId = current.remoteSessionId;
    return switch (current) {
      WebRtcPreparing() => WebRtcPreparing(
        sessionId,
        controlChannel: _controlChannelState,
        screenCapture: _screenCaptureStatus,
      ),
      WebRtcAnswering() => WebRtcAnswering(
        sessionId,
        controlChannel: _controlChannelState,
        screenCapture: _screenCaptureStatus,
      ),
      WebRtcConnecting() => WebRtcConnecting(
        sessionId,
        controlChannel: _controlChannelState,
        screenCapture: _screenCaptureStatus,
      ),
      WebRtcConnected() => WebRtcConnected(
        sessionId,
        controlChannel: _controlChannelState,
        screenCapture: _screenCaptureStatus,
      ),
      WebRtcInterrupted() => WebRtcInterrupted(
        sessionId,
        controlChannel: _controlChannelState,
        screenCapture: _screenCaptureStatus,
      ),
      // A negotiation that is over carries no channel any more.
      WebRtcFailed() => WebRtcFailed(
        sessionId,
        screenCapture: _screenCaptureStatus,
      ),
      WebRtcClosed() => WebRtcClosed(
        sessionId,
        screenCapture: _screenCaptureStatus,
      ),
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
  ///
  /// [keepRemoteIce] is for the one caller that releases the old peer on
  /// behalf of a new offer: the remote candidates queued by then were sent
  /// after that offer, for the connection about to be built, and the offer flow
  /// already emptied the queue of everything older.
  Future<void> _releasePeer({bool keepRemoteIce = false}) async {
    // Before the channel goes: no queued command outlives the connection it
    // came in on. A gesture already running cannot be recalled and is left to
    // finish, and its ack finds the generation moved on. A remote touch is
    // cancelled first, since it would not finish by itself.
    _commandQueue.discardPending();

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
    if (!keepRemoteIce) _pendingRemoteIce.clear();
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
    _orphanCaptureTimer?.cancel();
    _orphanCaptureTimer = null;
    await _platformStopSubscription.cancel();
    await _evidenceSubscription?.cancel();
    await _teardownPeer();
    // The screen goes with the application. A capture that outlived the
    // process that authorised it would be a notification the user cannot get
    // rid of, over a MediaProjection nothing is reading.
    await _stopScreenCapture();
    await _touches.dispose();
    return super.close();
  }
}
