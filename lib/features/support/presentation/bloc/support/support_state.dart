part of 'support_bloc.dart';

/// What the backend last said about this device's support request.
///
/// Every one of these states is the result of a REST answer. None of them is
/// ever produced by a realtime event, and none of them is invented locally:
/// that is what lets the tablet survive a lost `support:assigned`, a restart or
/// a dead network without ever showing a technician who is not really there.
sealed class SupportState extends Equatable {
  const SupportState();

  @override
  List<Object?> get props => const [];
}

/// Nothing has been asked yet.
final class SupportInitial extends SupportState {
  const SupportInitial();
}

/// The first `GET /support-requests/current` of this session is in flight.
final class SupportLoading extends SupportState {
  const SupportLoading();
}

/// The backend answered that there is no active request.
///
/// Also where the terminal statuses land — `REJECTED`, `CANCELLED`,
/// `COMPLETED` — once the backend has confirmed them.
final class SupportIdle extends SupportState {
  const SupportIdle({this.lastFailure});

  /// Why the previous attempt did not go through, when there was one. Shown as
  /// a short note; the user can simply try again.
  final Failure? lastFailure;

  @override
  List<Object?> get props => [lastFailure];
}

/// `POST /support-requests` is in flight. A second press cannot start another.
final class SupportCreating extends SupportState {
  const SupportCreating();
}

/// Shared shape of the three active statuses.
sealed class SupportRequestActive extends SupportState {
  const SupportRequestActive(this.request, {this.busy = false, this.lastFailure});

  /// As the backend last returned it. The `id` used by accept/reject/cancel
  /// comes from here, so it is always a value received over an authenticated
  /// call.
  final SupportRequest request;

  /// An accept/reject/cancel call is in flight: the buttons are disabled and no
  /// second one can start.
  final bool busy;

  /// Why the last action did not go through. The request itself is unchanged —
  /// a failed call is never treated as if it had succeeded.
  final Failure? lastFailure;

  @override
  List<Object?> get props => [request, busy, lastFailure];
}

/// `WAITING` — sent, nobody has taken it yet.
final class SupportWaiting extends SupportRequestActive {
  const SupportWaiting(super.request, {super.busy, super.lastFailure});
}

/// `ASSIGNED` — a technician is asking for permission. The user has to answer.
final class SupportAssigned extends SupportRequestActive {
  const SupportAssigned(super.request, {super.busy, super.lastFailure});
}

/// `ACCEPTED` — the user authorised that technician. No session exists yet.
final class SupportAccepted extends SupportRequestActive {
  const SupportAccepted(super.request, {super.busy, super.lastFailure});
}

/// The backend could not be asked, and nothing is known. Deliberately distinct
/// from [SupportIdle]: "there is no request" and "I could not find out" must
/// never look the same to the user.
final class SupportUnavailable extends SupportState {
  const SupportUnavailable(this.failure);

  final Failure failure;

  @override
  List<Object?> get props => [failure];
}
