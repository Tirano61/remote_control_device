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
  const RemoteSessionIdle({this.lastFailure});

  /// Why the previous attempt did not go through, when there was one. Shown as
  /// a short note; nothing is blocked by it.
  final Failure? lastFailure;

  @override
  List<Object?> get props => [lastFailure];
}

/// Shared shape of the two live statuses.
sealed class RemoteSessionLive extends RemoteSessionState {
  const RemoteSessionLive(
    this.session, {
    this.closing = false,
    this.lastFailure,
  });

  /// As the backend last returned it. The `id` used by
  /// `POST /device/remote-sessions/:id/close` comes from here, so it is always
  /// a value received over an authenticated call.
  final RemoteSession session;

  /// A close is in flight: the button is disabled and a second press cannot
  /// start another.
  final bool closing;

  /// Why the last action did not go through. The session itself is unchanged —
  /// a failed close is never treated as if it had succeeded.
  final Failure? lastFailure;

  @override
  List<Object?> get props => [session, closing, lastFailure];
}

/// `CONNECTING` — the session exists and both ends may start connecting. Every
/// session is born here and stays until the technician reports that the remote
/// connection came up.
final class RemoteSessionConnecting extends RemoteSessionLive {
  const RemoteSessionConnecting(
    super.session, {
    super.closing,
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
  const RemoteSessionActive(super.session, {super.closing, super.lastFailure});
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
