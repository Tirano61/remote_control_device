import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/accept_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/cancel_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/load_current_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/reject_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/request_support.dart';
import 'package:remote_control_device/features/support/presentation/bloc/support/support_bloc.dart';

import '../../../fakes/support_fakes.dart';

void main() {
  late FakeSupportRepository repository;
  late SupportBloc bloc;

  setUp(() {
    repository = FakeSupportRepository();
    bloc = SupportBloc(
      requestSupport: RequestSupport(repository),
      loadCurrentSupportRequest: LoadCurrentSupportRequest(repository),
      acceptSupportRequest: AcceptSupportRequest(repository),
      rejectSupportRequest: RejectSupportRequest(repository),
      cancelSupportRequest: CancelSupportRequest(repository),
    );
  });

  tearDown(() async => bloc.close());

  /// Lets queued events and their awaited calls settle.
  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> reach(SupportEvent event) async {
    bloc.add(event);
    await settle();
  }

  Future<void> reachWaiting() async {
    repository.currentResult = const Ok<SupportRequest?>(waitingRequest);
    await reach(const SupportSyncRequested());
  }

  Future<void> reachAssigned() async {
    repository.currentResult = const Ok<SupportRequest?>(assignedRequest);
    await reach(const SupportSyncRequested());
  }

  Future<void> reachAccepted() async {
    repository.currentResult = const Ok<SupportRequest?>(acceptedRequest);
    await reach(const SupportSyncRequested());
  }

  group('reading the current request', () {
    test('an empty answer is idle, not a failure', () async {
      await reach(const SupportSyncRequested());

      expect(bloc.state, const SupportIdle());
      expect(repository.currentCount, 1);
    });

    test('recovers a WAITING request after a restart or a reconnection', () async {
      await reachWaiting();

      expect(bloc.state, isA<SupportWaiting>());
      expect((bloc.state as SupportWaiting).request.id, testSupportRequestId);
    });

    test('recovers an ASSIGNED request even though no event ever arrived', () async {
      // The tablet was offline while the technician took the request, so
      // `support:assigned` was lost. The reconnection sync is the whole
      // recovery: nothing else is needed and nothing else is consulted.
      await reachAssigned();

      expect(bloc.state, isA<SupportAssigned>());
      expect(
        (bloc.state as SupportAssigned).request.technician?.name,
        testTechnicianName,
      );
    });

    test('a terminal status coming back from the backend means idle', () async {
      repository.currentResult = const Ok<SupportRequest?>(rejectedRequest);

      await reach(const SupportSyncRequested());

      expect(bloc.state, const SupportIdle());
    });

    test('an unreachable backend with nothing known says so', () async {
      repository.currentResult = currentUnreachable;

      await reach(const SupportSyncRequested());

      expect(bloc.state, isA<SupportUnavailable>());
      expect((bloc.state as SupportUnavailable).failure, isA<NetworkFailure>());
    });

    test('a failed sync never erases a request already on screen', () async {
      await reachWaiting();
      repository.currentResult = currentUnreachable;

      await reach(const SupportSyncRequested());

      // Losing the network does not withdraw a pending request: only the
      // backend can say the request is gone.
      expect(bloc.state, isA<SupportWaiting>());
    });
  });

  group('requesting assistance', () {
    test('a successful create leaves the request WAITING', () async {
      await reach(const SupportSyncRequested());

      await reach(const SupportRequested());

      expect(repository.createCount, 1);
      expect(bloc.state, isA<SupportWaiting>());
    });

    test('a double tap produces exactly one request', () async {
      await reach(const SupportSyncRequested());

      bloc
        ..add(const SupportRequested())
        ..add(const SupportRequested());
      await settle();

      expect(repository.createCount, 1);
      expect(bloc.state, isA<SupportWaiting>());
    });

    test('a create that fails on the network stays idle and retryable', () async {
      await reach(const SupportSyncRequested());
      repository.createResult = supportUnreachable;

      await reach(const SupportRequested());

      expect(bloc.state, isA<SupportIdle>());
      expect((bloc.state as SupportIdle).lastFailure, isA<NetworkFailure>());
      // Nothing was invented locally; a retry is a genuine second attempt.
      expect(repository.currentCount, 1);
    });

    test('a 409 adopts the request the backend already holds', () async {
      await reach(const SupportSyncRequested());
      repository.createResult = supportConflict;
      repository.currentResult = const Ok<SupportRequest?>(waitingRequest);

      await reach(const SupportRequested());

      expect(bloc.state, isA<SupportWaiting>());
      expect(repository.currentCount, 2);
      expect((bloc.state as SupportWaiting).lastFailure, isA<ConflictFailure>());
    });

    test('nothing is created while a request is already active', () async {
      await reachWaiting();

      await reach(const SupportRequested());

      expect(repository.createCount, 0);
    });
  });

  group('an assignment announced over the socket', () {
    test('is answered by re-reading REST, and REST decides', () async {
      await reachWaiting();
      repository.currentResult = const Ok<SupportRequest?>(assignedRequest);

      await reach(const SupportAssignmentAnnounced(testSupportRequestId));

      expect(repository.currentCount, 2);
      expect(bloc.state, isA<SupportAssigned>());
    });

    test('does not by itself make a request assigned', () async {
      await reachWaiting();
      // The event says a technician took it; the backend has not caught up (or
      // the event was about something else entirely). The event loses.
      repository.currentResult = const Ok<SupportRequest?>(waitingRequest);

      await reach(const SupportAssignmentAnnounced(testSupportRequestId));

      expect(bloc.state, isA<SupportWaiting>());
    });

    test('an announcement for another request still re-reads the truth', () async {
      await reachWaiting();
      repository.currentResult = const Ok<SupportRequest?>(assignedRequest);

      await reach(const SupportAssignmentAnnounced(testOtherSupportRequestId));

      expect(repository.currentCount, 2);
      expect(bloc.state, isA<SupportAssigned>());
    });

    test('never authorises the technician on its own', () async {
      await reachWaiting();
      repository.currentResult = const Ok<SupportRequest?>(assignedRequest);

      await reach(const SupportAssignmentAnnounced(testSupportRequestId));

      // Consent is a press, and nothing else in the application may stand in
      // for it.
      expect(repository.acceptCount, 0);
      expect(bloc.state, isNot(isA<SupportAccepted>()));
    });
  });

  group('answering an assigned request', () {
    test('PERMITIR accepts, using the id the backend gave', () async {
      await reachAssigned();

      await reach(const SupportAcceptRequested());

      expect(repository.acceptCount, 1);
      expect(repository.actedOnIds, [testSupportRequestId]);
      expect(bloc.state, isA<SupportAccepted>());
    });

    test('RECHAZAR ends in idle once the backend confirms', () async {
      await reachAssigned();

      await reach(const SupportRejectRequested());

      expect(repository.rejectCount, 1);
      expect(bloc.state, isA<SupportIdle>());
    });

    test('a second press while one answer is in flight does nothing', () async {
      await reachAssigned();

      bloc
        ..add(const SupportAcceptRequested())
        ..add(const SupportAcceptRequested());
      await settle();

      expect(repository.acceptCount, 1);
    });

    test('an answer lost on the network leaves the request untouched', () async {
      await reachAssigned();
      repository.acceptResult = supportUnreachable;

      await reach(const SupportAcceptRequested());

      // Not accepted: a call whose outcome is unknown must never be shown as a
      // granted authorisation.
      expect(bloc.state, isA<SupportAssigned>());
      expect((bloc.state as SupportAssigned).busy, isFalse);
      expect((bloc.state as SupportAssigned).lastFailure, isA<NetworkFailure>());
    });

    test('accept is refused from a status the contract does not allow', () async {
      await reachWaiting();

      await reach(const SupportAcceptRequested());

      expect(repository.acceptCount, 0);
    });
  });

  group('withdrawing', () {
    test('cancelling a WAITING request ends in idle', () async {
      await reachWaiting();

      await reach(const SupportCancelRequested());

      expect(repository.cancelCount, 1);
      expect(repository.actedOnIds, [testSupportRequestId]);
      expect(bloc.state, isA<SupportIdle>());
    });

    test('cancelling an ACCEPTED request is allowed while no session exists', () async {
      await reachAccepted();

      await reach(const SupportCancelRequested());

      expect(repository.cancelCount, 1);
      expect(bloc.state, isA<SupportIdle>());
    });

    test('a 409 on cancel re-reads state instead of guessing', () async {
      await reachAccepted();
      repository.cancelResult = supportConflict;
      // A remote session started in the meantime, so the request is still there
      // — this build cannot close a session, and does not pretend to.
      repository.currentResult = const Ok<SupportRequest?>(acceptedRequest);

      await reach(const SupportCancelRequested());

      expect(bloc.state, isA<SupportAccepted>());
      expect((bloc.state as SupportAccepted).lastFailure, isA<ConflictFailure>());
      expect(repository.currentCount, 2);
    });

    test('a 404 is treated the same way: re-read, do not invent', () async {
      await reachWaiting();
      repository.cancelResult = supportNotFound;
      repository.currentResult = const Ok<SupportRequest?>(null);

      await reach(const SupportCancelRequested());

      expect(bloc.state, isA<SupportIdle>());
      expect((bloc.state as SupportIdle).lastFailure, isA<NotFoundFailure>());
    });
  });

  group('losing the device identity', () {
    test('drops everything held locally', () async {
      await reachAssigned();

      await reach(const SupportResetRequested());

      expect(bloc.state, const SupportInitial());
    });

    test('an answer that arrives after the reset is discarded', () async {
      await reachAssigned();

      bloc
        ..add(const SupportAcceptRequested())
        ..add(const SupportResetRequested());
      await settle();

      // The call did go out, but its result belongs to a device this
      // installation no longer is.
      expect(repository.acceptCount, 1);
      expect(bloc.state, const SupportInitial());
    });
  });
}
