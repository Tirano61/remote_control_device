part of 'remote_session_bloc.dart';

/// What the backend last said about this device's remote session.
///
/// Every one of these states is the result of a REST answer.
/// `remote-session:created` never produces [RemoteSessionConnecting] and
/// `remote-session:closed` never produces [RemoteSessionIdle]: both events only
/// cause a read, and the read decides. That is what lets the tablet survive a
/// lost event, a restart or a dead network without ever showing an assistance
/// session that is not really there — or hiding one that is.
sealed class RemoteSessionState extends Equatable {
  const RemoteSessionState();

  @override
  List<Object?> get props => const [];
}

/// Nothing has been asked yet.
final class RemoteSessionInitial extends RemoteSessionState {
  const RemoteSessionInitial();
}

/// The first `GET /device/remote-sessions/current` of this session is in
/// flight.
final class RemoteSessionLoading extends RemoteSessionState {
  const RemoteSessionLoading();
}

/// The backend answered that there is no live session.
///
/// The normal state for most of the application's life, and also where an
/// accepted support request waiting for its technician sits: `ACCEPTED` without
/// a session is expected, not an error. A `CLOSED` session lands here too —
/// `/current` stops returning it the moment it ends.
final class RemoteSessionIdle extends RemoteSessionState {
  const RemoteSessionIdle({this.lastFailure, this.lastClosure});

  /// Why the previous attempt did not go through, when there was one. Shown as
  /// a short note; nothing is blocked by it.
  final Failure? lastFailure;

  /// Who closed the assistance this tablet was last taking part in, when it
  /// was closed from the other side (by the technician, or by the backend on
  /// its own) rather than with FINALIZAR here. [RemoteSessionEndedBy.unknown]
  /// when the tablet only found out because `/current` stopped returning it.
  /// Shown as a short note above the support request; it decides nothing.
  final RemoteSessionEndedBy? lastClosure;

  @override
  List<Object?> get props => [lastFailure, lastClosure];
}

/// Whether the tablet can currently *confirm* that a live session is still
/// authorised.
///
/// ```text
/// confirmed   the realtime channel (the only way the backend can tell this
///             tablet that a session was closed) is up, and a `/current` read
///             that started after it last came up returned this session live.
///             Commands may run, if the session is ACTIVE.
///
/// suspended   anything else: the channel is down, or it came back and the
///             backend has not been asked again yet, or the read that would
///             have confirmed it failed or started too early. No command runs.
///             The peer connection and the screen are kept for a bounded grace
///             period and then taken down: see RemoteSessionBloc.
/// ```
enum RemoteSessionAuthority { confirmed, suspended }

/// Shared shape of the two live statuses.
///
/// A live state is never one the user of this tablet has ended. The moment
/// `FINALIZAR ASISTENCIA` is pressed the session leaves this family for
/// [RemoteSessionEndedLocally], and nothing — a failed close, a late read, a
/// realtime event, a restart — brings that same session back into it.
sealed class RemoteSessionLive extends RemoteSessionState {
  const RemoteSessionLive(
    this.session, {
    required this.authority,
    this.lastFailure,
  });

  /// As the backend last returned it. The `id` used by
  /// `POST /device/remote-sessions/:id/close` comes from here, so it is always
  /// a value received over an authenticated call.
  final RemoteSession session;

  /// Whether the tablet can confirm right now that the backend still holds
  /// this session live. Only a [RemoteSessionAuthority.confirmed]
  /// [RemoteSessionActive] lets a remote command run.
  final RemoteSessionAuthority authority;

  /// Why the last read did not go through. The session itself is unchanged: a
  /// tablet that lost the network is not told the assistance ended.
  final Failure? lastFailure;

  bool get isSuspended => authority == RemoteSessionAuthority.suspended;

  @override
  List<Object?> get props => [session, authority, lastFailure];
}

/// `CONNECTING` — the session exists and both ends may start connecting. Every
/// session is born here and stays until the technician reports that the remote
/// connection came up.
final class RemoteSessionConnecting extends RemoteSessionLive {
  const RemoteSessionConnecting(
    super.session, {
    required super.authority,
    super.lastFailure,
  });
}

/// `ACTIVE` — the backend recorded that the remote connection is established,
/// and `session.connectedAt` says when.
///
/// Reached like every other state here: a read of
/// `GET /device/remote-sessions/current` answered `ACTIVE`. The transition
/// itself belongs to `remote_control_web`, which calls
/// `POST /remote-sessions/:id/activate`; this client has no such call, and
/// `remote-session:active` only makes it read.
///
/// It says nothing about the peer connection, which this bloc cannot see. The
/// two are the same fact from different ends, and neither is derived from the
/// other.
final class RemoteSessionActive extends RemoteSessionLive {
  const RemoteSessionActive(
    super.session, {
    required super.authority,
    super.lastFailure,
  });
}

/// The user of this tablet pressed `FINALIZAR ASISTENCIA` for
/// [remoteSessionId], and the backend has not yet confirmed it `CLOSED`.
///
/// Entered *before* anything is sent, and on purpose not a live state: every
/// coordinator reads it as "no assistance", so the control channel stops
/// obeying, a remote touch is let go, the peer connection is closed, the
/// signaling room is left and the screen capture is stopped — all without
/// waiting for the network.
///
/// What it is not is a confirmed close. The backend may still hold the session
/// `ACTIVE`, and the screen says exactly that: the assistance ended on this
/// tablet, and the server has or has not been told.
///
/// ```text
/// confirming     the close is on its way to the backend
/// lastFailure    it did not get there (network, 5xx, 401...): the session is
///                still ended here, and is reconciled on the next reconnection,
///                on the next start of the application, or on REINTENTAR
/// ```
///
/// Leaving it takes a backend answer: the `CLOSED` session from the close
/// itself, or a `/current` that no longer returns this session. It never leads
/// back to [RemoteSessionLive] for the same session. A *different* session can
/// only begin the normal way — a new request the user accepts.
final class RemoteSessionEndedLocally extends RemoteSessionState {
  const RemoteSessionEndedLocally(
    this.remoteSessionId, {
    this.confirming = false,
    this.lastFailure,
    this.reason = RemoteSessionLocalEndReason.userRequest,
  });

  /// The session that was ended, as the backend last returned it. Never taken
  /// from a widget or a realtime payload.
  final String remoteSessionId;

  /// A close is on its way to the backend: a second one is not started.
  final bool confirming;

  /// Why the backend could not confirm the close the last time it was asked.
  final Failure? lastFailure;

  /// Why the tablet ended it. Only changes what the user is told.
  final RemoteSessionLocalEndReason reason;

  @override
  List<Object?> get props => [remoteSessionId, confirming, lastFailure, reason];
}

/// Why an assistance was ended on this tablet.
enum RemoteSessionLocalEndReason {
  /// The user pressed FINALIZAR ASISTENCIA.
  userRequest,

  /// The tablet could not confirm with the backend, within the grace period,
  /// that the session was still authorised, and ended it by itself.
  authorityLost,
}

/// The backend closed [remoteSessionId] (the technician did, or the backend
/// did on its own with `SYSTEM`) and said so over `remote-session:closed`.
///
/// Entered the moment the event names the session held, before anything is
/// read. Like [RemoteSessionEndedLocally] it is not a live state, so control,
/// the peer connection, the signaling room and the screen capture are all let
/// go at once. `/current` is read straight afterwards; an empty answer moves
/// the state on to [RemoteSessionIdle], and no answer (late, stale or wrong)
/// ever makes this same session live again. A *different* session can only
/// begin the normal way, with a new request the user accepts.
final class RemoteSessionClosedRemotely extends RemoteSessionState {
  const RemoteSessionClosedRemotely(
    this.remoteSessionId, {
    this.endedBy = RemoteSessionEndedBy.unknown,
    this.lastFailure,
  });

  /// The session that was held, as the backend last returned it. The event's
  /// id only ever *matches* it; it is never adopted from the payload.
  final String remoteSessionId;

  final RemoteSessionEndedBy endedBy;

  /// Why the read that follows the event did not go through.
  final Failure? lastFailure;

  @override
  List<Object?> get props => [remoteSessionId, endedBy, lastFailure];
}

/// The backend could not be asked, and nothing is known. Deliberately distinct
/// from [RemoteSessionIdle]: "there is no session" and "I could not find out"
/// must never look the same, because one of them means a technician may still
/// be connected.
final class RemoteSessionUnavailable extends RemoteSessionState {
  const RemoteSessionUnavailable(this.failure);

  final Failure failure;

  @override
  List<Object?> get props => [failure];
}
