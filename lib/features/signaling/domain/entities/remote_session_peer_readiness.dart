import 'package:equatable/equatable.dart';

/// The other end of a `RemoteSession` is in its signaling room.
///
/// Two things carry this fact, and they are the same fact seen at two moments:
///
/// ```text
/// JoinRemoteSessionAck.peerJoined   was the peer already there when this
///                                   device joined?
///
/// remote-session:peer-joined        the peer arrived afterwards.
/// ```
///
/// What it is **not** is permission to start negotiating. `remote_control_web`
/// is the offerer for this system and `remote_control_device` the answerer, so
/// readiness on this side is only ever recorded: a device that created a peer
/// connection on hearing it would be the second end doing so, and both would
/// produce an offer.
///
/// It is also not durable. Like the join itself, it describes one Socket.IO
/// connection and is never persisted; a reconnection starts with no readiness
/// at all until the next ACK answers it.
class RemoteSessionPeerReady extends Equatable {
  const RemoteSessionPeerReady(this.remoteSessionId);

  /// The session the peer joined. Checked against the session this client is
  /// joined to before it is believed — a notice naming another session says
  /// nothing about this one.
  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];

  @override
  String toString() => 'RemoteSessionPeerReady($remoteSessionId)';
}
