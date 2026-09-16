import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:remote_control_device/core/config/app_config.dart';
import 'package:remote_control_device/features/device/data/realtime/device_realtime_payloads.dart';
import 'package:remote_control_device/features/device/data/realtime/device_socket_options.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_channel.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
import 'package:remote_control_device/features/signaling/data/signaling_events.dart';
import 'package:remote_control_device/features/signaling/data/signaling_payloads.dart';
import 'package:remote_control_device/features/signaling/domain/entities/join_remote_session_result.dart';
import 'package:remote_control_device/features/signaling/domain/entities/remote_session_peer_readiness.dart';
import 'package:remote_control_device/features/signaling/domain/entities/remote_signaling_message.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_error_code.dart';
import 'package:remote_control_device/features/signaling/domain/entities/signaling_relay_result.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_answer.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_ice_candidate.dart';
import 'package:remote_control_device/features/signaling/domain/entities/webrtc_offer.dart';

/// The only place in the application that knows Socket.IO exists.
///
/// It translates the package's callbacks into [DeviceRealtimeSignal]s and
/// [RemoteSignalingMessage]s and keeps every decision about *what they mean*
/// out of here: this class never renews a token, never touches credentials,
/// never decides when to join and never decides to give up.
///
/// One socket per token. [connect] always builds a fresh socket rather than
/// re-opening the existing one, because the `auth` map is captured when the
/// socket is created — re-opening would re-present the token it was built with,
/// which is precisely the token that was just refused.
///
/// It serves two ports over that one socket, which is what `REALTIME.md`
/// describes: a device has a single authenticated `/devices` connection, and
/// presence, the server-to-device notices and the WebRTC signaling relay all
/// ride on it. `DeviceRealtimeBloc` sees only [DeviceRealtimeClient] and
/// `SignalingBloc` sees only [DeviceSignalingClient]; the fact that they are
/// the same object is known to the composition root alone.
class SocketIoDeviceRealtimeClient implements DeviceRealtimeChannel {
  SocketIoDeviceRealtimeClient({required AppConfig config}) : _config = config;

  static const String _loggerName = 'realtime';

  final AppConfig _config;
  final StreamController<DeviceRealtimeSignal> _signals =
      StreamController<DeviceRealtimeSignal>.broadcast();

  /// Kept apart from [_signals] so that the signaling consumer never has to
  /// see — or filter out — connection events it has no business reading.
  final StreamController<RemoteSignalingMessage> _signalingMessages =
      StreamController<RemoteSignalingMessage>.broadcast();

  /// Readiness notices. A third controller rather than a third kind of signal
  /// on one of the other two: `remote-session:peer-joined` is neither a
  /// connection event nor a relayed `webrtc:*`, and folding it into either
  /// would make a consumer filter out something it should never have seen.
  final StreamController<RemoteSessionPeerReady> _peerReadiness =
      StreamController<RemoteSessionPeerReady>.broadcast();

  io.Socket? _socket;

  /// Removers returned by every registered listener, so teardown is explicit
  /// and not left to the package's own bookkeeping.
  final List<void Function()> _listenerRemovers = [];

  @override
  Stream<DeviceRealtimeSignal> get signals => _signals.stream;

  @override
  Stream<RemoteSignalingMessage> get signalingMessages =>
      _signalingMessages.stream;

  @override
  Stream<RemoteSessionPeerReady> get peerReadiness => _peerReadiness.stream;

  @override
  void connect(String deviceToken) {
    _releaseSocket();
    if (_signals.isClosed) return;

    _log('connecting to ${AppConfig.deviceRealtimeNamespace}');
    final socket = io.io(
      _config.deviceRealtimeUrl,
      buildDeviceSocketOptions(config: _config, deviceToken: deviceToken),
    );
    // Listeners first, connection second: auto-connect is off precisely so that
    // no event can be missed and none can be registered twice.
    _bindListeners(socket);
    _socket = socket;
    socket.connect();
  }

  @override
  void disconnect() {
    if (_socket != null) _log('disconnecting');
    _releaseSocket();
  }

  @override
  Future<void> dispose() async {
    _releaseSocket();
    if (!_signals.isClosed) await _signals.close();
    if (!_signalingMessages.isClosed) await _signalingMessages.close();
    if (!_peerReadiness.isClosed) await _peerReadiness.close();
  }

  void _bindListeners(io.Socket socket) {
    _listenerRemovers.addAll([
      socket.onConnect((_) {
        _log('connected');
        _emit(const RealtimeConnected());
      }),
      socket.on(deviceConnectedEvent, (Object? payload) {
        final confirmation = parseDeviceConnectedPayload(payload);
        if (confirmation == null) {
          _log('$deviceConnectedEvent ignored: unexpected payload');
          return;
        }
        // publicId is an identifier, not a credential: safe to log.
        _log('$deviceConnectedEvent for ${confirmation.publicId}');
        _emit(RealtimeIdentityConfirmed(confirmation));
      }),
      socket.on(supportAssignedEvent, (Object? payload) {
        final assigned = parseSupportAssignedPayload(payload);
        if (assigned == null) {
          _log('$supportAssignedEvent ignored: unexpected payload');
          return;
        }
        // A support request id is an operational identifier, not a credential.
        _log('$supportAssignedEvent for ${assigned.supportRequestId}');
        _emit(assigned);
      }),
      socket.on(remoteSessionCreatedEvent, (Object? payload) {
        final created = parseRemoteSessionCreatedPayload(payload);
        if (created == null) {
          _log('$remoteSessionCreatedEvent ignored: unexpected payload');
          return;
        }
        // A remote session id is an operational identifier, not a credential.
        _log('$remoteSessionCreatedEvent for ${created.remoteSessionId}');
        _emit(created);
      }),
      socket.on(remoteSessionActiveEvent, (Object? payload) {
        final activated = parseRemoteSessionActivePayload(payload);
        if (activated == null) {
          _log('$remoteSessionActiveEvent ignored: unexpected payload');
          return;
        }
        _log('$remoteSessionActiveEvent for ${activated.remoteSessionId}');
        _emit(activated);
      }),
      socket.on(remoteSessionClosedEvent, (Object? payload) {
        final closed = parseRemoteSessionClosedPayload(payload);
        if (closed == null) {
          _log('$remoteSessionClosedEvent ignored: unexpected payload');
          return;
        }
        _log('$remoteSessionClosedEvent for ${closed.remoteSessionId}');
        _emit(closed);
      }),
      socket.on(remoteSessionPeerJoinedEvent, (Object? payload) {
        final ready = parseRemoteSessionPeerJoinedPayload(payload);
        if (ready == null) {
          _log('$remoteSessionPeerJoinedEvent ignored: unexpected payload');
          return;
        }
        _log('$remoteSessionPeerJoinedEvent for ${ready.remoteSessionId}');
        if (_peerReadiness.isClosed) return;
        _peerReadiness.add(ready);
      }),
      socket.on(webRtcOfferEvent, (Object? payload) {
        final message = parseWebRtcOfferPayload(payload);
        if (message == null) {
          _log('$webRtcOfferEvent ignored: unexpected payload');
          return;
        }
        // The session id is an operational identifier; the SDP never is.
        _log('$webRtcOfferEvent received for ${message.remoteSessionId}');
        _emitSignaling(message);
      }),
      socket.on(webRtcAnswerEvent, (Object? payload) {
        final message = parseWebRtcAnswerPayload(payload);
        if (message == null) {
          _log('$webRtcAnswerEvent ignored: unexpected payload');
          return;
        }
        _log('$webRtcAnswerEvent received for ${message.remoteSessionId}');
        _emitSignaling(message);
      }),
      socket.on(webRtcIceCandidateEvent, (Object? payload) {
        final message = parseWebRtcIceCandidatePayload(payload);
        if (message == null) {
          _log('$webRtcIceCandidateEvent ignored: unexpected payload');
          return;
        }
        _log('$webRtcIceCandidateEvent received for ${message.remoteSessionId}');
        _emitSignaling(message);
      }),
      socket.onDisconnect((_) {
        _log('disconnected');
        _emit(const RealtimeDisconnected());
      }),
      socket.onConnectError((Object? error) {
        // Only the classification is logged. The raw error may carry the
        // handshake it failed on, and with it the Authorization payload.
        if (isUnauthorizedHandshakeError(error)) {
          _log('handshake rejected by the namespace');
          _emit(const RealtimeHandshakeRejected());
        } else {
          _log('connection attempt failed');
          _emit(const RealtimeConnectFailed());
        }
      }),
      socket.onReconnectAttempt((_) {
        _log('reconnect attempt');
        _emit(const RealtimeReconnectAttempt());
      }),
    ]);
  }

  /// Detaches every listener *before* closing, so the intentional close does
  /// not come back as a `disconnect` signal that would read as a network drop.
  void _releaseSocket() {
    final socket = _socket;
    _socket = null;
    for (final remove in _listenerRemovers) {
      remove();
    }
    _listenerRemovers.clear();
    socket?.dispose();
  }

  // ------------------------------------------------------------- signaling

  @override
  Future<JoinRemoteSessionResult> joinRemoteSession(
    String remoteSessionId,
  ) async {
    final payload = buildRemoteSessionJoinPayload(remoteSessionId);
    if (payload == null) {
      // Only reachable if an id were built locally instead of read from an
      // authenticated backend answer, which is a programming error, not a
      // transient one — so it is reported as the contract error it would be.
      _log('$remoteSessionJoinEvent not sent: the session id is not a UUID');
      return const RemoteSessionJoinRefused(SignalingErrorCode.invalidPayload);
    }

    _log('$remoteSessionJoinEvent requested for $remoteSessionId');
    final result = parseJoinRemoteSessionAck(
      await _emitWithAck(remoteSessionJoinEvent, payload),
    );

    if (result is RemoteSessionJoined &&
        result.remoteSessionId != remoteSessionId) {
      // An answer about another session is not an answer to this request.
      _log('$remoteSessionJoinEvent answered about a different session');
      return const RemoteSessionJoinUnanswered();
    }
    _log(switch (result) {
      // Readiness is an operational fact about the peer's room membership and
      // carries nothing sensitive, so it is safe to log alongside the id.
      RemoteSessionJoined(:final peerJoined) =>
        'signaling joined: $remoteSessionId (peer joined: $peerJoined)',
      // The code is the stable part of the contract and carries no secret.
      RemoteSessionJoinRefused(:final error) =>
        'signaling join refused (${error.name}): $remoteSessionId',
      RemoteSessionJoinUnanswered() =>
        'signaling join unanswered: $remoteSessionId',
    });
    return result;
  }

  @override
  Future<SignalingRelayResult> sendOffer(WebRtcOffer offer) => _relay(
    event: webRtcOfferEvent,
    remoteSessionId: offer.remoteSessionId,
    payload: buildWebRtcOfferPayload(offer),
  );

  @override
  Future<SignalingRelayResult> sendAnswer(WebRtcAnswer answer) => _relay(
    event: webRtcAnswerEvent,
    remoteSessionId: answer.remoteSessionId,
    payload: buildWebRtcAnswerPayload(answer),
  );

  @override
  Future<SignalingRelayResult> sendIceCandidate(
    WebRtcIceCandidate candidate,
  ) => _relay(
    event: webRtcIceCandidateEvent,
    remoteSessionId: candidate.remoteSessionId,
    payload: buildWebRtcIceCandidatePayload(candidate),
  );

  /// The one path every `webrtc:*` takes out.
  ///
  /// A `null` [payload] means the builder refused it against the documented
  /// DTO, so it is never put on the wire: emitting it could only earn an
  /// `INVALID_PAYLOAD`, and the client already knows that.
  Future<SignalingRelayResult> _relay({
    required String event,
    required String remoteSessionId,
    required Map<String, dynamic>? payload,
  }) async {
    if (payload == null) {
      _log('$event not sent: the payload is outside the documented limits');
      return const SignalingRelayNotSent(SignalingNotSentReason.invalidPayload);
    }

    final result = parseSignalingRelayAck(await _emitWithAck(event, payload));
    _log(switch (result) {
      SignalingRelayDelivered() => '$event delivered: $remoteSessionId',
      SignalingRelayRefused(:final error) =>
        '$event refused (${error.name}): $remoteSessionId',
      SignalingRelayUnanswered() => '$event unanswered: $remoteSessionId',
      SignalingRelayNotSent() => '$event not sent: $remoteSessionId',
    });
    return result;
  }

  /// Emits and waits for the ACK, with two guards the package does not give.
  ///
  /// Without a live socket it answers `null` immediately instead of emitting:
  /// `socket_io_client` buffers a packet sent while disconnected and delivers
  /// it on the next connection, which for a join means joining a session the
  /// client may no longer be in — exactly the stale join this must never make.
  ///
  /// And it gives up after [AppConfig.signalingAckTimeout]. The backend always
  /// answers its ACKs, so a silence means the connection died between the emit
  /// and the answer; a caller left awaiting it forever would stall the join
  /// state machine for the rest of the session.
  Future<Object?> _emitWithAck(String event, Map<String, dynamic> payload) {
    final socket = _socket;
    if (socket == null || !socket.connected) {
      _log('$event not sent: no live connection');
      return Future<Object?>.value();
    }

    final completer = Completer<Object?>();
    final timeout = Timer(_config.signalingAckTimeout, () {
      if (!completer.isCompleted) completer.complete();
    });
    // Optional positional: the package applies the ACK with whatever the
    // server sent, which may be no argument at all.
    socket.emitWithAck(
      event,
      payload,
      ack: ([Object? data]) {
        timeout.cancel();
        if (!completer.isCompleted) completer.complete(data);
      },
    );
    return completer.future;
  }

  // -------------------------------------------------------------- plumbing

  void _emit(DeviceRealtimeSignal signal) {
    if (_signals.isClosed) return;
    _signals.add(signal);
  }

  void _emitSignaling(RemoteSignalingMessage message) {
    if (_signalingMessages.isClosed) return;
    _signalingMessages.add(message);
  }

  void _log(String message) {
    if (kDebugMode) developer.log(message, name: _loggerName);
  }
}
