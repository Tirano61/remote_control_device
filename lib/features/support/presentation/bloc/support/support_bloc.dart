import 'dart:developer' as developer;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request_status.dart';
import 'package:remote_control_device/features/support/domain/usecases/accept_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/cancel_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/load_current_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/reject_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/request_support.dart';

part 'support_event.dart';
part 'support_state.dart';

/// Owns the assistance flow, with one rule above all the others:
///
/// ```text
/// REST is the state. Realtime only says "look again".
/// ```
///
/// Every state this bloc emits comes from a support-request payload the backend
/// returned. `support:assigned` never produces [SupportAssigned] by itself — it
/// produces a `GET /support-requests/current`, and *that* answer decides. The
/// price is one extra call per event; what it buys is that a tablet which was
/// asleep, offline or simply unlucky ends up in the same state as one that
/// received every event, because the recovery path and the happy path are the
/// same code.
///
/// The other rule is consent: [SupportAccepted] is reachable only through
/// [SupportAcceptRequested], which only a press on `PERMITIR` raises. No event,
/// reconnection or resynchronisation can authorise a technician.
class SupportBloc extends Bloc<SupportEvent, SupportState> {
  SupportBloc({
    required RequestSupport requestSupport,
    required LoadCurrentSupportRequest loadCurrentSupportRequest,
    required AcceptSupportRequest acceptSupportRequest,
    required RejectSupportRequest rejectSupportRequest,
    required CancelSupportRequest cancelSupportRequest,
  }) : _requestSupport = requestSupport,
       _loadCurrentSupportRequest = loadCurrentSupportRequest,
       _acceptSupportRequest = acceptSupportRequest,
       _rejectSupportRequest = rejectSupportRequest,
       _cancelSupportRequest = cancelSupportRequest,
       super(const SupportInitial()) {
    on<SupportSyncRequested>(_onSyncRequested);
    on<SupportAssignmentAnnounced>(_onAssignmentAnnounced);
    on<SupportRequested>(_onSupportRequested);
    on<SupportAcceptRequested>(_onAcceptRequested);
    on<SupportRejectRequested>(_onRejectRequested);
    on<SupportCancelRequested>(_onCancelRequested);
    on<SupportResetRequested>(_onResetRequested);
  }

  static const String _loggerName = 'support';

  final RequestSupport _requestSupport;
  final LoadCurrentSupportRequest _loadCurrentSupportRequest;
  final AcceptSupportRequest _acceptSupportRequest;
  final RejectSupportRequest _rejectSupportRequest;
  final CancelSupportRequest _cancelSupportRequest;

  /// Bumped when the device identity is dropped. An answer that arrives after
  /// that belongs to a device this installation no longer is, so it is
  /// discarded instead of being written over the cleared state.
  int _generation = 0;

  // ----------------------------------------------------------------- syncing

  Future<void> _onSyncRequested(
    SupportSyncRequested event,
    Emitter<SupportState> emit,
  ) async {
    // An action already in flight will settle the state with the backend's own
    // answer; a sync racing it could only overwrite that with an older read.
    if (_operationInFlight) return;
    await _sync(emit);
  }

  Future<void> _onAssignmentAnnounced(
    SupportAssignmentAnnounced event,
    Emitter<SupportState> emit,
  ) async {
    if (_operationInFlight) return;

    final known = state;
    if (known is SupportRequestActive &&
        known.request.id != event.supportRequestId) {
      // Not a reason to distrust the answer that follows — the backend is asked
      // either way — but worth knowing: the local copy was already stale.
      _log('assignment announced for a request other than the one held');
    }
    await _sync(emit);
  }

  /// Reads `/current` and adopts whatever it says.
  ///
  /// A known active request is never dropped because the call failed: losing
  /// the network must not make a pending request disappear from the screen.
  /// Only a backend answer changes an active state.
  ///
  /// Callers that are themselves an operation — a create, or an action that came
  /// back `404`/`409` — reach this directly: re-reading is the whole point of
  /// those paths, which is why the in-flight guard lives in the event handlers
  /// above rather than here.
  Future<void> _sync(Emitter<SupportState> emit, {Failure? reason}) async {
    final generation = _generation;
    final known = state;
    if (known is SupportInitial || known is SupportUnavailable) {
      emit(const SupportLoading());
    }

    final result = await _loadCurrentSupportRequest();
    if (generation != _generation) return;

    switch (result) {
      case Ok<SupportRequest?>(:final value):
        emit(_stateFor(value, lastFailure: reason));
      case Err<SupportRequest?>(:final failure):
        emit(
          known is SupportRequestActive
              ? _stateFor(known.request, lastFailure: reason)
              : SupportUnavailable(reason ?? failure),
        );
    }
  }

  // ---------------------------------------------------------------- creating

  Future<void> _onSupportRequested(
    SupportRequested event,
    Emitter<SupportState> emit,
  ) async {
    // This guard is the whole double-tap protection: the first press moves the
    // state to [SupportCreating] before it awaits anything, so the second press
    // finds a state that is not idle and does nothing.
    if (state is! SupportIdle) return;

    final generation = _generation;
    emit(const SupportCreating());

    final result = await _requestSupport();
    if (generation != _generation) return;

    switch (result) {
      case Ok<SupportRequest>(:final value):
        emit(_stateFor(value));
      case Err<SupportRequest>(:final failure):
        if (_meansStaleState(failure)) {
          // The backend already holds an active request for this device, and
          // its version is the real one.
          await _sync(emit, reason: failure);
          return;
        }
        emit(SupportIdle(lastFailure: failure));
    }
  }

  // ----------------------------------------------------------------- actions

  Future<void> _onAcceptRequested(
    SupportAcceptRequested event,
    Emitter<SupportState> emit,
  ) => _act(
    emit,
    allowedFrom: SupportRequestStatus.assigned,
    action: _acceptSupportRequest.call,
  );

  Future<void> _onRejectRequested(
    SupportRejectRequested event,
    Emitter<SupportState> emit,
  ) => _act(
    emit,
    allowedFrom: SupportRequestStatus.assigned,
    action: _rejectSupportRequest.call,
  );

  Future<void> _onCancelRequested(
    SupportCancelRequested event,
    Emitter<SupportState> emit,
  ) => _act(emit, action: _cancelSupportRequest.call);

  /// Runs one of the three transitions on the request currently held.
  ///
  /// The id comes from the state, which was built from an authenticated
  /// response — never from the widget that raised the event. The backend still
  /// checks ownership; this only makes sure the client never invents an id to
  /// ask about.
  Future<void> _act(
    Emitter<SupportState> emit, {
    required Future<Result<SupportRequest>> Function(String id) action,
    SupportRequestStatus? allowedFrom,
  }) async {
    final current = state;
    if (current is! SupportRequestActive || current.busy) return;
    if (allowedFrom != null && current.request.status != allowedFrom) return;

    final generation = _generation;
    final request = current.request;
    emit(_stateFor(request, busy: true));

    final result = await action(request.id);
    if (generation != _generation) return;

    switch (result) {
      case Ok<SupportRequest>(:final value):
        // Terminal statuses included: a confirmed REJECTED or CANCELLED becomes
        // [SupportIdle] here, and only here.
        emit(_stateFor(value));
      case Err<SupportRequest>(:final failure):
        if (_meansStaleState(failure)) {
          await _sync(emit, reason: failure);
          return;
        }
        // Nothing is known to have happened at the backend, so the request
        // stays exactly as it was and the user may try again.
        emit(_stateFor(request, lastFailure: failure));
    }
  }

  // ------------------------------------------------------------------- reset

  Future<void> _onResetRequested(
    SupportResetRequested event,
    Emitter<SupportState> emit,
  ) async {
    _generation++;
    emit(const SupportInitial());
  }

  // ---------------------------------------------------------------- plumbing

  bool get _operationInFlight => switch (state) {
    SupportCreating() => true,
    SupportRequestActive(:final busy) => busy,
    _ => false,
  };

  /// `404` and `409` both mean the same thing here: what this client believed
  /// is no longer what the backend holds. The contract is explicit that the
  /// client re-reads state rather than interpreting the message.
  static bool _meansStaleState(Failure failure) =>
      failure is ConflictFailure || failure is NotFoundFailure;

  /// The single mapping from a backend payload to a screen state.
  static SupportState _stateFor(
    SupportRequest? request, {
    bool busy = false,
    Failure? lastFailure,
  }) {
    if (request == null) return SupportIdle(lastFailure: lastFailure);

    return switch (request.status) {
      SupportRequestStatus.waiting => SupportWaiting(
        request,
        busy: busy,
        lastFailure: lastFailure,
      ),
      SupportRequestStatus.assigned => SupportAssigned(
        request,
        busy: busy,
        lastFailure: lastFailure,
      ),
      SupportRequestStatus.accepted => SupportAccepted(
        request,
        busy: busy,
        lastFailure: lastFailure,
      ),
      // A terminal status is not an active request: there is nothing to show
      // and nothing to act on. `unknown` lands here too — a status this build
      // cannot interpret must not be rendered as if it were one it can. Should
      // the backend still hold it as active, the next attempt to create a
      // request answers 409 and the state is re-read.
      SupportRequestStatus.rejected ||
      SupportRequestStatus.cancelled ||
      SupportRequestStatus.completed ||
      SupportRequestStatus.unknown => SupportIdle(lastFailure: lastFailure),
    };
  }

  void _log(String message) {
    if (kDebugMode) developer.log(message, name: _loggerName);
  }
}
