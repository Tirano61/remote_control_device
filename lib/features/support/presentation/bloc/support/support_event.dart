part of 'support_bloc.dart';

sealed class SupportEvent extends Equatable {
  const SupportEvent();

  @override
  List<Object?> get props => const [];
}

/// Re-read the authoritative state from `GET /support-requests/current`.
///
/// Raised whenever something suggests the backend may have moved on: the
/// realtime channel came up, it came back after a drop, or the user asked to
/// retry. It is also the recovery path for an event that never arrived.
final class SupportSyncRequested extends SupportEvent {
  const SupportSyncRequested();
}

/// `support:assigned` was received for [supportRequestId].
///
/// Handled exactly like a sync: the event is a *cue*, and the id travels with
/// it only so a mismatch against the locally held request can be noticed. The
/// state that follows is whatever REST answers — never what this event said.
final class SupportAssignmentAnnounced extends SupportEvent {
  const SupportAssignmentAnnounced(this.supportRequestId);

  final String supportRequestId;

  @override
  List<Object?> get props => [supportRequestId];
}

/// The user pressed "request assistance".
final class SupportRequested extends SupportEvent {
  const SupportRequested();
}

/// The user pressed `PERMITIR`. Only a deliberate press produces this event.
final class SupportAcceptRequested extends SupportEvent {
  const SupportAcceptRequested();
}

/// The user pressed `RECHAZAR`.
final class SupportRejectRequested extends SupportEvent {
  const SupportRejectRequested();
}

/// The user pressed `CANCELAR`.
final class SupportCancelRequested extends SupportEvent {
  const SupportCancelRequested();
}

/// The device identity this state belonged to is gone (revoked credential,
/// re-enrollment). Everything held locally must be dropped.
final class SupportResetRequested extends SupportEvent {
  const SupportResetRequested();
}
