import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';

import '../../../fakes/remote_session_fakes.dart';

void main() {
  late FakeRemoteSessionRepository repository;
  late RemoteSessionBloc bloc;

  setUp(() {
    repository = FakeRemoteSessionRepository();
    bloc = RemoteSessionBloc(
      loadCurrentRemoteSession: LoadCurrentRemoteSession(repository),
      closeRemoteSession: CloseRemoteSession(repository),
    );
  });

  tearDown(() async => bloc.close());

  /// Lets the queued event, its awaited call and the emission all complete.
  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> sync() async {
    bloc.add(const RemoteSessionSyncRequested());
    await settle();
  }

  /// Brings the bloc to a live CONNECTING session, the way a
  /// remote-session:created or a reconnection would.
  Future<void> reachConnecting() async {
    repository.currentResult = connectingRemoteSession;
    await sync();
    expect(bloc.state, isA<RemoteSessionConnecting>());
  }

  group('an ACCEPTED request without a session yet', () {
    test('is idle, not an error: the technician has still to press start',
        () async {
      repository.currentResult = noRemoteSession;

      await sync();

      expect(repository.currentCount, 1);
      expect(bloc.state, const RemoteSessionIdle());
      expect((bloc.state as RemoteSessionIdle).lastFailure, isNull);
    });
  });

  group('remote-session:created', () {
    test('causes a read, and the read is what produces the session', () async {
      repository.currentResult = connectingRemoteSession;

      bloc.add(const RemoteSessionAnnounced(testRemoteSessionId));
      await settle();

      expect(repository.currentCount, 1);
      final state = bloc.state;
      expect(state, isA<RemoteSessionConnecting>());
      // Built from the REST payload — technician block included — which the
      // event never carries.
      expect((state as RemoteSessionConnecting).session, connectingSession);
      expect(state.session.technician?.name, testRemoteSessionTechnician.name);
    });

    test('an event the backend cannot confirm produces no session at all',
        () async {
      // The socket announced something; `/current` says there is nothing. The
      // backend wins, every time.
      repository.currentResult = noRemoteSession;

      bloc.add(const RemoteSessionAnnounced(testRemoteSessionId));
      await settle();

      expect(bloc.state, const RemoteSessionIdle());
    });

    test('an id other than the one held still adopts the backend answer',
        () async {
      await reachConnecting();

      bloc.add(const RemoteSessionAnnounced(testOtherRemoteSessionId));
      await settle();

      expect(repository.currentCount, 2);
      final state = bloc.state as RemoteSessionConnecting;
      // The id came back from REST; the one in the event was never adopted.
      expect(state.session.id, testRemoteSessionId);
    });
  });

  group('a lost event', () {
    test('is recovered by the next read, with no event at all', () async {
      // Nothing was announced: the tablet was asleep when the session was
      // created. The plain sync a reconnection raises finds it.
      repository.currentResult = connectingRemoteSession;

      await sync();

      expect(bloc.state, isA<RemoteSessionConnecting>());
    });
  });

  group('ACTIVE', () {
    test('is supported even though no backend path writes it', () async {
      repository.currentResult = activeRemoteSession;

      await sync();

      expect(bloc.state, isA<RemoteSessionActive>());
      expect((bloc.state as RemoteSessionActive).session, activeSession);
    });
  });

  group('closing from the tablet', () {
    test('posts the id the backend gave and then re-reads /current', () async {
      await reachConnecting();
      repository.currentResult = noRemoteSession;

      bloc.add(const RemoteSessionCloseRequested());
      await settle();

      expect(repository.closeCount, 1);
      // Never an id typed by a user or taken off the socket.
      expect(repository.closedIds, [testRemoteSessionId]);
      // The contract's own recovery call confirms the close.
      expect(repository.currentCount, 2);
      expect(bloc.state, const RemoteSessionIdle());
    });

    test('a second press while the close is in flight does nothing', () async {
      await reachConnecting();
      repository.currentResult = noRemoteSession;

      bloc
        ..add(const RemoteSessionCloseRequested())
        ..add(const RemoteSessionCloseRequested());
      await settle();

      expect(repository.closeCount, 1);
    });

    test('a sync racing the close cannot overwrite its answer', () async {
      await reachConnecting();
      repository.currentResult = noRemoteSession;

      bloc
        ..add(const RemoteSessionCloseRequested())
        ..add(const RemoteSessionSyncRequested());
      await settle();

      expect(bloc.state, const RemoteSessionIdle());
    });

    test('a close that failed for the network leaves the session alone',
        () async {
      await reachConnecting();
      repository.closeResult = closeUnreachable;

      bloc.add(const RemoteSessionCloseRequested());
      await settle();

      // Nothing is known to have happened at the backend: the session is still
      // there and the user may press again.
      final state = bloc.state;
      expect(state, isA<RemoteSessionConnecting>());
      expect((state as RemoteSessionConnecting).session, connectingSession);
      expect(state.closing, isFalse);
      expect(state.lastFailure, isA<NetworkFailure>());
      expect(repository.currentCount, 1);
    });
  });

  group('a close that lost a race with the backend', () {
    test('adopts the real state after a 409 instead of inventing one', () async {
      await reachConnecting();
      repository.closeResult = closeConflict;
      // The technician closed a moment earlier.
      repository.currentResult = noRemoteSession;

      bloc.add(const RemoteSessionCloseRequested());
      await settle();

      expect(repository.currentCount, 2);
      expect(bloc.state, const RemoteSessionIdle(lastFailure: ConflictFailure()));
    });

    test('adopts the real state after a 404 too', () async {
      await reachConnecting();
      repository.closeResult = closeNotFound;
      repository.currentResult = noRemoteSession;

      bloc.add(const RemoteSessionCloseRequested());
      await settle();

      expect(bloc.state, const RemoteSessionIdle(lastFailure: NotFoundFailure()));
    });

    test('a 409 whose re-read still finds the session keeps it', () async {
      // The other documented 409: the session is live but its request cannot be
      // completed. Nothing local is invented either way.
      await reachConnecting();
      repository.closeResult = closeConflict;

      bloc.add(const RemoteSessionCloseRequested());
      await settle();

      final state = bloc.state;
      expect(state, isA<RemoteSessionConnecting>());
      expect((state as RemoteSessionConnecting).closing, isFalse);
    });
  });

  group('the technician closing', () {
    test('remote-session:closed causes a read, and the read ends it', () async {
      await reachConnecting();
      repository.currentResult = noRemoteSession;

      bloc.add(const RemoteSessionClosureAnnounced(testRemoteSessionId));
      await settle();

      expect(repository.currentCount, 2);
      expect(bloc.state, const RemoteSessionIdle());
    });

    test('an event the backend contradicts does not end the session', () async {
      await reachConnecting();
      // `/current` still holds it: whatever that event was about, this session
      // is live, and the user is not told the assistance ended.
      bloc.add(const RemoteSessionClosureAnnounced(testRemoteSessionId));
      await settle();

      expect(bloc.state, isA<RemoteSessionConnecting>());
    });
  });

  group('losing the network', () {
    test('never turns a live session into a closed one', () async {
      await reachConnecting();
      repository.currentResult = remoteSessionUnreachable;

      await sync();

      // The single most important assertion in this file: a tablet that lost
      // Wi-Fi must not tell the user the assistance is over.
      final state = bloc.state;
      expect(state, isA<RemoteSessionConnecting>());
      expect((state as RemoteSessionConnecting).session, connectingSession);
    });

    test('lets the next read reconcile once the network is back', () async {
      await reachConnecting();
      repository.currentResult = remoteSessionUnreachable;
      await sync();

      repository.currentResult = noRemoteSession;
      await sync();

      expect(repository.currentCount, 3);
      expect(bloc.state, const RemoteSessionIdle());
    });

    test('a first read that fails says so, and does not claim there is none',
        () async {
      repository.currentResult = remoteSessionUnreachable;

      await sync();

      // "I could not find out" and "there is no session" must never look the
      // same: one of them means a technician may still be connected.
      expect(bloc.state, isA<RemoteSessionUnavailable>());
      expect((bloc.state as RemoteSessionUnavailable).failure,
          isA<NetworkFailure>());
    });

    test('a failed re-read does not un-know a confirmed absence', () async {
      repository.currentResult = noRemoteSession;
      await sync();
      repository.currentResult = remoteSessionUnreachable;

      await sync();

      expect(bloc.state, isA<RemoteSessionIdle>());
    });

    test('retrying after an unavailable first read recovers', () async {
      repository.currentResult = remoteSessionUnreachable;
      await sync();
      repository.currentResult = connectingRemoteSession;

      await sync();

      expect(bloc.state, isA<RemoteSessionConnecting>());
    });
  });

  group('a dropped device identity', () {
    test('clears the session and discards the answer already in flight',
        () async {
      await reachConnecting();
      // A read is under way when the credential turns out to be revoked.
      repository.currentResult = connectingRemoteSession;
      bloc.add(const RemoteSessionSyncRequested());
      bloc.add(const RemoteSessionResetRequested());
      await settle();

      // The answer belonged to a device this installation no longer is.
      expect(bloc.state, const RemoteSessionInitial());
    });

    test('a close answering after the reset cannot resurrect a session',
        () async {
      await reachConnecting();
      bloc.add(const RemoteSessionCloseRequested());
      bloc.add(const RemoteSessionResetRequested());
      await settle();

      expect(bloc.state, const RemoteSessionInitial());
    });
  });

  group('the states the screen distinguishes', () {
    test('are loading, none, live, closing and unknown', () async {
      final seen = <RemoteSessionState>[];
      final subscription = bloc.stream.listen(seen.add);

      repository.currentResult = connectingRemoteSession;
      await sync();
      repository.currentQueue.add(noRemoteSession);
      bloc.add(const RemoteSessionCloseRequested());
      await settle();

      await subscription.cancel();

      expect(seen.map((state) => state.runtimeType), [
        RemoteSessionLoading,
        RemoteSessionConnecting,
        // The close in flight — what the prompt calls "closing".
        RemoteSessionConnecting,
        RemoteSessionIdle,
      ]);
      expect((seen[1] as RemoteSessionConnecting).closing, isFalse);
      expect((seen[2] as RemoteSessionConnecting).closing, isTrue);
    });

    test('a CLOSED session is never shown as live', () async {
      repository.currentResult = const Ok<RemoteSession?>(closedSession);

      await sync();

      expect(bloc.state, const RemoteSessionIdle());
    });
  });
}
