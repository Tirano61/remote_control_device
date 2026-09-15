import 'dart:async';

import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_device/features/signaling/domain/entities/remote_signaling_message.dart';
import 'package:remote_control_device/features/signaling/presentation/bloc/signaling/signaling_bloc.dart';
import 'package:remote_control_device/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

/// Feeds the WebRTC layer the three things it cannot see for itself.
///
/// ```text
/// SignalingBloc.incoming   webrtc:offer          ──> the one trigger
///                          webrtc:ice-candidate  ──> applied or queued
///
/// SignalingBloc.state      joined session id     ──> may this device relay?
///
/// RemoteSessionBloc.state  live session id       ──> does the assistance exist?
/// ```
///
/// Only the first of those starts anything. The other two are preconditions the
/// offer is checked against, and their disappearance is what ends a
/// negotiation — never their arrival.
///
/// `webrtc:answer` is deliberately not forwarded. This device is the answerer
/// and creates every answer itself; one arriving from the peer would mean the
/// web had answered an offer this device never made, so it is dropped where it
/// is parsed rather than given to a peer connection.
///
/// As with every other coordinator here, neither bloc learns the other exists.
/// `SignalingBloc` knows nothing about peer connections, `RemoteSessionBloc`
/// knows nothing about either, and `WebRtcSessionBloc` sees three ports and no
/// blocs at all.
class WebRtcCoordinator {
  WebRtcCoordinator({
    required SignalingBloc signalingBloc,
    required RemoteSessionBloc remoteSessionBloc,
    required WebRtcSessionBloc webRtcBloc,
  }) : _signalingBloc = signalingBloc,
       _remoteSessionBloc = remoteSessionBloc,
       _webRtcBloc = webRtcBloc;

  final SignalingBloc _signalingBloc;
  final RemoteSessionBloc _remoteSessionBloc;
  final WebRtcSessionBloc _webRtcBloc;

  StreamSubscription<RemoteSignalingMessage>? _incomingSubscription;
  StreamSubscription<SignalingState>? _signalingSubscription;
  StreamSubscription<RemoteSessionState>? _remoteSessionSubscription;

  void start() {
    // The current values count, not only future transitions: on a restart the
    // socket may already be joined and the session already recovered by the
    // time this is wired, and an offer arriving then must find both known.
    _webRtcBloc.add(
      WebRtcSignalingAvailabilityChanged(_joinedIdOf(_signalingBloc.state)),
    );
    _webRtcBloc.add(
      WebRtcRemoteSessionChanged(_liveIdOf(_remoteSessionBloc.state)),
    );

    _incomingSubscription = _signalingBloc.incoming.listen(_onSignalingMessage);
    _signalingSubscription = _signalingBloc.stream.listen(
      (state) => _webRtcBloc.add(
        WebRtcSignalingAvailabilityChanged(_joinedIdOf(state)),
      ),
    );
    _remoteSessionSubscription = _remoteSessionBloc.stream.listen(
      (state) => _webRtcBloc.add(WebRtcRemoteSessionChanged(_liveIdOf(state))),
    );
  }

  void _onSignalingMessage(RemoteSignalingMessage message) {
    switch (message) {
      case OfferReceived(:final offer):
        _webRtcBloc.add(WebRtcOfferReceived(offer));
      case IceCandidateReceived(:final candidate):
        _webRtcBloc.add(WebRtcRemoteIceReceived(candidate));
      case AnswerReceived():
        // Nothing answers this device: it is the answerer. An answer arriving
        // here would be the web replying to an offer that was never made, so
        // it is ignored rather than applied.
        return;
    }
  }

  /// The session this device may relay for, or `null`. Only [SignalingJoined]
  /// qualifies — joining, failed and idle all mean the same thing to a peer
  /// connection: nothing can be sent.
  static String? _joinedIdOf(SignalingState state) => switch (state) {
    SignalingJoined(:final remoteSessionId) => remoteSessionId,
    _ => null,
  };

  /// The live session, or `null`. `RemoteSessionLive` is exactly the backend's
  /// `CONNECTING`/`ACTIVE`; everything else — no session, one that could not be
  /// read, a cleared identity — is "no assistance", which is the safe reading.
  static String? _liveIdOf(RemoteSessionState state) => switch (state) {
    RemoteSessionLive(:final session) => session.id,
    _ => null,
  };

  Future<void> dispose() async {
    await _incomingSubscription?.cancel();
    await _signalingSubscription?.cancel();
    await _remoteSessionSubscription?.cancel();
    _incomingSubscription = null;
    _signalingSubscription = null;
    _remoteSessionSubscription = null;
  }
}
