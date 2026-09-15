import 'dart:async';
import 'dart:developer' as developer;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/features/signaling/domain/entities/join_remote_session_result.dart';
import 'package:remote_control_device/features/signaling/domain/entities/remote_session_peer_readiness.dart';
import 'package:remote_control_device/features/signaling/domain/entities/remote_signaling_message.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_error_code.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_relay_result.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_answer.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_ice_candidate.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_offer.dart';
import 'package:remote_control_device/features/signaling/domain/signaling_client.dart';
import 'package:remote_control_device/features/webrtc/domain/webrtc_signaling_gateway.dart';

part 'signaling_event.dart';
part 'signaling_state.dart';

/// Owns the signaling room membership of the `/devices` socket.
///
/// One rule decides everything here, and it is the contract's:
///
/// ```text
/// remote-session:join is mandatory before any webrtc:*,
/// and a fresh socket has no joined session.
/// ```
///
/// So the join is not a step in a setup sequence that happens once — it is a
/// fact that has to be re-established every time the socket is replaced. This
/// bloc is what re-establishes it, and what refuses to emit anything before it
/// holds:
///
/// ```text
/// socket connected + RemoteSession CONNECTING/ACTIVE
///        ↓
/// remote-session:join
///        ↓
/// ACK joined=true ──> SignalingJoined ──> webrtc:* allowed
/// ACK joined=false ─> SignalingUnavailable ──> nothing is emitted, and the
///                     join is not retried until something real changes
/// ```
///
/// What it is deliberately **not**: it never reads or writes a remote session,
/// never touches a credential, never persists anything, and never moves a
/// session to `ACTIVE`. Signaling changes no backend row — the contract is
/// explicit — so a joined room means exactly one thing: this socket may relay.
///
/// It is also where the WebRTC layer plugs in. [incoming], [sendOffer],
/// [sendAnswer] and [sendIceCandidate] are the whole surface a peer connection
/// needs; none of them exposes Socket.IO, an ACK shape or
/// `DeviceRealtimeClient`.
///
/// Two of those four are declared by [WebRtcSignalingGateway], which this bloc
/// satisfies as it stands. The peer connection is an answerer and sends exactly
/// an answer and its candidates, so the port it depends on names those two and
/// nothing else — `sendOffer` stays available to this bloc's own API and out of
/// reach of the WebRTC feature, which has no business creating an offer.
class SignalingBloc extends Bloc<SignalingEvent, SignalingState>
    implements WebRtcSignalingGateway {
  SignalingBloc({required DeviceSignalingClient client})
    : _client = client,
      super(const SignalingIdle()) {
    on<SignalingJoinRequested>(_onJoinRequested);
    on<SignalingConnectionLost>(_onConnectionLost);
    on<SignalingSessionEnded>(_onSessionEnded);
    on<SignalingJoinLost>(_onJoinLost);
    on<SignalingRelayDenied>(_onRelayDenied);
    on<SignalingPeerReady>(_onPeerReady);
    on<SignalingRetryRequested>(_onRetryRequested);

    _messages = _client.signalingMessages.listen(_onMessageReceived);
    _readiness = _client.peerReadiness.listen(_onPeerReadinessReceived);
  }

  static const String _loggerName = 'signaling';

  final DeviceSignalingClient _client;

  late final StreamSubscription<RemoteSignalingMessage> _messages;
  late final StreamSubscription<RemoteSessionPeerReady> _readiness;

  /// Messages that survived the session filter. A separate controller rather
  /// than a filtered view of the client's stream, so that a late subscriber —
  /// the peer connection built in a later prompt — attaches to something whose
  /// lifetime this bloc controls.
  final StreamController<RemoteSignalingMessage> _accepted =
      StreamController<RemoteSignalingMessage>.broadcast();

  /// Bumped whenever the situation a join was started under stops holding: the
  /// socket dropped, the session ended or changed, the join was lost. An ACK
  /// that arrives after that answers a question nobody is asking any more, and
  /// writing it into the state would resurrect a join that is already gone.
  int _generation = 0;

  /// The session this client may relay for, or `null`. Derived from the state
  /// rather than tracked beside it: two copies of the same fact drift, and this
  /// particular fact is the one that authorises putting SDP on the wire.
  String? get joinedRemoteSessionId => switch (state) {
    SignalingJoined(:final remoteSessionId) => remoteSessionId,
    _ => null,
  };

  /// Whether the technician was last seen in the same session room. `false`
  /// while not joined, because readiness is a property of a join.
  bool get peerJoined => switch (state) {
    SignalingJoined(:final peerJoined) => peerJoined,
    _ => false,
  };

  /// Every `webrtc:*` that arrived for the session this client is joined to.
  ///
  /// This is the typed stream the WebRTC layer consumes. Nothing is applied to
  /// a peer connection here — there is none yet — and nothing is buffered: a
  /// message that arrives with no listener is dropped, exactly as the backend
  /// drops one relayed into an empty room.
  Stream<RemoteSignalingMessage> get incoming => _accepted.stream;

  // ------------------------------------------------------------------ join

  Future<void> _onJoinRequested(
    SignalingJoinRequested event,
    Emitter<SignalingState> emit,
  ) async {
    final remoteSessionId = event.remoteSessionId;

    // The guard against duplicate and concurrent joins, and it is the state
    // itself: already joining it, already joined to it, or already failed on it
    // are all "nothing to do". Only the last one needs explaining — a failed
    // join is not retried against unchanged circumstances, because it would
    // fail identically and the pair would spin.
    switch (state) {
      case SignalingJoining(remoteSessionId: final pending)
          when pending == remoteSessionId:
        return;
      case SignalingJoined(remoteSessionId: final joined)
          when joined == remoteSessionId:
        return;
      case SignalingUnavailable(remoteSessionId: final failed)
          when failed == remoteSessionId:
        return;
      case _:
        break;
    }

    // Emitted before the first await, which is what makes the guard above hold
    // for a second event delivered while this one is waiting on its ACK.
    _generation++;
    final generation = _generation;
    emit(SignalingJoining(remoteSessionId));

    final result = await _client.joinRemoteSession(remoteSessionId);
    if (generation != _generation) return;

    emit(switch (result) {
      RemoteSessionJoined(:final peerJoined) => SignalingJoined(
        remoteSessionId,
        peerJoined: peerJoined,
      ),
      RemoteSessionJoinRefused(:final error) => SignalingUnavailable(
        remoteSessionId,
        error: error,
      ),
      // No ACK at all: the socket died between the emit and the answer. The
      // next connection raises a fresh join, so nothing has to be scheduled.
      RemoteSessionJoinUnanswered() => SignalingUnavailable(remoteSessionId),
    });
  }

  Future<void> _onConnectionLost(
    SignalingConnectionLost event,
    Emitter<SignalingState> emit,
  ) async {
    if (state is SignalingIdle) return;
    _log('signaling reset: the realtime channel is down');
    _reset(emit);
  }

  Future<void> _onSessionEnded(
    SignalingSessionEnded event,
    Emitter<SignalingState> emit,
  ) async {
    if (state is SignalingIdle) return;
    _log('signaling reset: there is no live remote session');
    _reset(emit);
  }

  Future<void> _onJoinLost(
    SignalingJoinLost event,
    Emitter<SignalingState> emit,
  ) async {
    // Only the session that is actually joined can lose its join; a late
    // NOT_JOINED about a previous session must not disturb the current one.
    if (joinedRemoteSessionId != event.remoteSessionId) return;

    _log('signaling join lost, re-joining: ${event.remoteSessionId}');
    _reset(emit);
    // Back through the contract's own path. The refused message is not resent.
    add(SignalingJoinRequested(event.remoteSessionId));
  }

  Future<void> _onRelayDenied(
    SignalingRelayDenied event,
    Emitter<SignalingState> emit,
  ) async {
    if (joinedRemoteSessionId != event.remoteSessionId) return;

    _log('signaling denied for ${event.remoteSessionId}');
    // Not a re-join: the room membership is intact, the session behind it is
    // not. Asking to join again would be answered the same way. This lands in
    // the state the coordinator reconciles over REST.
    _generation++;
    emit(
      SignalingUnavailable(
        event.remoteSessionId,
        error: SignalingErrorCode.unauthorized,
      ),
    );
  }

  /// Records that the peer arrived after this device had already joined.
  ///
  /// Session isolation applies here as it does to every incoming payload: a
  /// notice naming a session this client is not joined to says nothing about
  /// the one it is joined to, and is dropped rather than followed.
  ///
  /// Nothing else happens. No peer connection is created, no offer is made and
  /// no message is sent — the state simply stops saying the room is empty.
  Future<void> _onPeerReady(
    SignalingPeerReady event,
    Emitter<SignalingState> emit,
  ) async {
    final current = state;
    if (current is! SignalingJoined) return;
    if (current.remoteSessionId != event.remoteSessionId) return;
    if (current.peerJoined) return;

    _log('peer ready for ${event.remoteSessionId}');
    emit(SignalingJoined(current.remoteSessionId, peerJoined: true));
  }

  Future<void> _onRetryRequested(
    SignalingRetryRequested event,
    Emitter<SignalingState> emit,
  ) async {
    final current = state;
    if (current is! SignalingUnavailable) return;

    final remoteSessionId = current.remoteSessionId;
    _reset(emit);
    add(SignalingJoinRequested(remoteSessionId));
  }

  /// Back to not-joined, and any answer still in flight discarded.
  void _reset(Emitter<SignalingState> emit) {
    _generation++;
    emit(const SignalingIdle());
  }

  // --------------------------------------------------------------- sending

  /// Emits `webrtc:offer` for the joined session.
  Future<SignalingRelayResult> sendOffer(WebRtcOffer offer) =>
      _relay(offer.remoteSessionId, () => _client.sendOffer(offer));

  /// Emits `webrtc:answer` for the joined session.
  @override
  Future<SignalingRelayResult> sendAnswer(WebRtcAnswer answer) =>
      _relay(answer.remoteSessionId, () => _client.sendAnswer(answer));

  /// Emits `webrtc:ice-candidate` for the joined session.
  @override
  Future<SignalingRelayResult> sendIceCandidate(WebRtcIceCandidate candidate) =>
      _relay(
        candidate.remoteSessionId,
        () => _client.sendIceCandidate(candidate),
      );

  /// The gate every outgoing message passes.
  ///
  /// Nothing is emitted before [SignalingJoined], and nothing is emitted for a
  /// session other than the joined one. Both would be answered by the backend
  /// anyway — that is what per-message re-validation is for — but a client that
  /// knows the answer has no business asking, and a caller gets a local result
  /// instead of a round trip.
  Future<SignalingRelayResult> _relay(
    String remoteSessionId,
    Future<SignalingRelayResult> Function() emit,
  ) async {
    final joined = joinedRemoteSessionId;
    if (joined == null || joined != remoteSessionId) {
      _log('outgoing signaling refused: not joined to $remoteSessionId');
      return const SignalingRelayNotSent(SignalingNotSentReason.notJoined);
    }

    final result = await emit();
    if (result is SignalingRelayRefused) {
      switch (result.error) {
        case SignalingErrorCode.notJoined:
          // The socket says the room membership this client believed in is
          // gone. The contract's instruction is to join again, not to resend.
          add(SignalingJoinLost(remoteSessionId));
        case SignalingErrorCode.unauthorized:
          // The membership is fine; the session behind it is not.
          add(SignalingRelayDenied(remoteSessionId));
        case SignalingErrorCode.invalidPayload:
        case SignalingErrorCode.unavailable:
        case SignalingErrorCode.unknown:
          // A bug in the payload, a transient server-side condition, or a code
          // this build cannot read. None of them says anything about the join,
          // so none of them touches it; the caller is told and decides. The
          // message is never resent on this client's own initiative —
          // signaling is ephemeral by design.
          break;
      }
    }
    return result;
  }

  // -------------------------------------------------------------- incoming

  /// Session isolation, applied to every message before anything downstream
  /// sees it.
  ///
  /// A message naming a session this client is not joined to is dropped — never
  /// followed. Adopting the session a payload names would let whatever is on
  /// the other end of the socket redirect this device's signaling, which is the
  /// one thing a room membership is supposed to prevent.
  void _onMessageReceived(RemoteSignalingMessage message) {
    final joined = joinedRemoteSessionId;
    if (joined == null) {
      _log('incoming signaling ignored: not joined to any session');
      return;
    }
    if (message.remoteSessionId != joined) {
      _log('incoming signaling ignored: it names another session');
      return;
    }
    if (_accepted.isClosed) return;

    // The kind and the session id only. SDP and candidate contents are never
    // logged, on either side of the wire.
    _log('${_describe(message)} accepted for $joined');
    _accepted.add(message);
  }

  void _onPeerReadinessReceived(RemoteSessionPeerReady ready) =>
      add(SignalingPeerReady(ready.remoteSessionId));

  static String _describe(RemoteSignalingMessage message) => switch (message) {
    OfferReceived() => 'offer received',
    AnswerReceived() => 'answer received',
    IceCandidateReceived() => 'ICE candidate received',
  };

  void _log(String message) {
    if (kDebugMode) developer.log(message, name: _loggerName);
  }

  @override
  Future<void> close() async {
    await _messages.cancel();
    await _readiness.cancel();
    await _accepted.close();
    // The socket is not disposed here: it belongs to `DeviceRealtimeBloc`, and
    // this bloc only ever had a second view of it.
    return super.close();
  }
}
