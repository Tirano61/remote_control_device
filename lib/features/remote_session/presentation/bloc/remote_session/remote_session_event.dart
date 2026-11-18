part of 'remote_session_bloc.dart';

sealed class RemoteSessionEvent extends Equatable {
  const RemoteSessionEvent();

  @override
  List<Object?> get props => const [];
}

/// Re-read the authoritative state from `GET /device/remote-sessions/current`.
///
/// Raised whenever something suggests the backend may have moved on: the
/// realtime channel came up or came back, the support request reached
/// `ACCEPTED`, or the user asked to retry. It is also the recovery path for an
/// event that never arrived and for an application that was restarted.
final class RemoteSessionSyncRequested extends RemoteSessionEvent {
  const RemoteSessionSyncRequested();
}

/// `remote-session:created` was received for [remoteSessionId].
///
/// Handled exactly like a sync: the event is a *cue*, and the id travels with
/// it only so a mismatch against the session already held can be noticed and
/// logged. The state that follows is whatever REST answers — never what this
/// event said, and the id this client would later close is never this one.
final class RemoteSessionAnnounced extends RemoteSessionEvent {
  const RemoteSessionAnnounced(this.remoteSessionId);

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// `remote-session:active` was received for [remoteSessionId]: the technician
/// reported that the remote connection came up and the backend wrote `ACTIVE`.
///
/// A cue like every other one, with one difference: it is *filtered*. A
/// creation or a closure is answered with a read whatever id it names, because
/// either may legitimately be news about a session this client does not hold
/// yet. An activation cannot be — it is the transition of a session that
/// already exists — so one naming a different session than the live one on
/// screen changes nothing here and is dropped without a call. Ownership never
/// moves because of a realtime payload.
///
/// It is also dropped once the session is already `ACTIVE`: the state the event
/// announces is the state already held, so re-reading could only spend a call
/// to be told the same thing.
final class RemoteSessionActivationAnnounced extends RemoteSessionEvent {
  const RemoteSessionActivationAnnounced(this.remoteSessionId);

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// `remote-session:closed` was received for [remoteSessionId]: the technician
/// ended the assistance, or the backend did on its own ([endedBy] `system`).
///
/// When it names the session held, the session leaves the live family at once
/// (control withdrawn, peer and screen taken down) and is never live again.
/// Then `/current` is read, as for every other cue, and decides what follows.
/// [endedBy] is only shown to the user.
final class RemoteSessionClosureAnnounced extends RemoteSessionEvent {
  const RemoteSessionClosureAnnounced(
    this.remoteSessionId, {
    this.endedBy = RemoteSessionEndedBy.unknown,
  });

  final String remoteSessionId;
  final RemoteSessionEndedBy endedBy;

  @override
  List<Object?> get props => [remoteSessionId, endedBy];
}

/// The channel through which the backend can withdraw a session (the
/// authenticated realtime connection) came up ([available]) or went down.
///
/// Losing it suspends a live session at once: no command runs until a fresh
/// `/current` read, started after the channel is back, confirms the session
/// again. Regaining it confirms nothing by itself.
final class RemoteSessionAuthorityChannelChanged extends RemoteSessionEvent {
  const RemoteSessionAuthorityChannelChanged({required this.available});

  final bool available;

  @override
  List<Object?> get props => [available];
}

/// The grace period of a suspended session ran out. Raised only by the bloc's
/// own timer.
final class _RemoteSessionAuthorityGraceExpired extends RemoteSessionEvent {
  const _RemoteSessionAuthorityGraceExpired(this.remoteSessionId);

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// The user pressed `FINALIZAR ASISTENCIA`, or `REINTENTAR` on an assistance
/// already ended here whose close the backend has not confirmed. Only a
/// deliberate press produces this event.
///
/// The first press ends the assistance on this tablet at once and for good;
/// the close sent to the backend only reports it. A repeat sends the close
/// again and never resumes anything.
final class RemoteSessionCloseRequested extends RemoteSessionEvent {
  const RemoteSessionCloseRequested();
}

/// The device identity this state belonged to is gone (revoked credential,
/// re-enrollment). Everything held locally must be dropped — a live session
/// must never outlive the identity that was authorised to hold it.
final class RemoteSessionResetRequested extends RemoteSessionEvent {
  const RemoteSessionResetRequested();
}
