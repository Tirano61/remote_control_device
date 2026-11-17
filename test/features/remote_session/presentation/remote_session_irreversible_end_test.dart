import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';

import '../../../fakes/remote_session_fakes.dart';
import '../../../fakes/support_fakes.dart';

/// FINALIZAR ASISTENCIA is irreversible on the tablet.
///
/// Every test here is a way the backend, the network or the application could
/// try to hand an ended session back as live, and the assertion is always the
/// same: it does not come back. Only its confirmation can change.
void main() {
  late FakeRemoteSessionRepository repository;
  late FakeEndedRemoteSessionStore store;
  late RemoteSessionBloc bloc;

  RemoteSessionBloc build() => RemoteSessionBloc(
    loadCurrentRemoteSession: LoadCurrentRemoteSession(repository),
    closeRemoteSession: CloseRemoteSession(repository),
    endedSessionStore: store,
  );

  setUp(() {
    repository = FakeRemoteSessionRepository();
    store = FakeEndedRemoteSessionStore();
    bloc = build();
  });

  tearDown(() async => bloc.close());

  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> sync() async {
    bloc.add(const RemoteSessionSyncRequested());
    await settle();
  }

  Future<void> reachActive() async {
    repository.currentResult = activatedRemoteSession;
    await sync();
    expect(bloc.state, isA<RemoteSessionActive>());
  }

  /// FINALIZAR with the backend unreachable: the situation C1 was about.
  Future<void> endWhileUnreachable() async {
    await reachActive();
    repository.closeResult = closeUnreachable;
    bloc.add(const RemoteSessionCloseRequested());
    await settle();
  }

  const endedUnconfirmed = RemoteSessionEndedLocally(
    testRemoteSessionId,
    lastFailure: NetworkFailure(),
  );

  group('Case A — a close the backend confirms', () {
    test('ends here first, then confirms, then rests at none', () async {
      await reachActive();
      final gate = Completer<void>();
      repository.closeGate = gate;
      repository.currentQueue.add(noRemoteSession);

      bloc.add(const RemoteSessionCloseRequested());
      await settle();

      // Ended before the backend has answered anything.
      expect(
        bloc.state,
        const RemoteSessionEndedLocally(testRemoteSessionId, confirming: true),
      );
      // Remembered before the close was even answered.
      expect(store.value, testRemoteSessionId);

      gate.complete();
      await settle();

      expect(bloc.state, const RemoteSessionIdle());
      expect(repository.closedIds, [testRemoteSessionId]);
      // Confirmed: the marker has nothing left to protect.
      expect(store.value, isNull);
    });
  });

  group('Case B — a close that cannot reach the backend', () {
    for (final (name, failure) in [
      ('network', const NetworkFailure()),
      ('a 5xx', const ServerFailure()),
      ('a 401', const AuthFailure()),
      ('a 400', const ValidationFailure()),
    ]) {
      test('$name never brings the session back', () async {
        await reachActive();
        repository.closeResult = Err<RemoteSession>(failure);

        bloc.add(const RemoteSessionCloseRequested());
        await settle();

        expect(
          bloc.state,
          RemoteSessionEndedLocally(testRemoteSessionId, lastFailure: failure),
        );
        // The confirmation is pending, and remembered across a restart.
        expect(store.value, testRemoteSessionId);
      });
    }

    test('a failed re-read keeps it ended, never live or unknown', () async {
      await endWhileUnreachable();
      repository.currentResult = remoteSessionUnreachable;

      await sync();

      expect(bloc.state, endedUnconfirmed);
      // Nothing was answered, so nothing was closed again either.
      expect(repository.closeCount, 1);
    });
  });

  group('Case C — /current still returns the session ACTIVE', () {
    test('it stays ended, and the close is sent once more', () async {
      await endWhileUnreachable();
      // The backend never heard of the close: it still holds the session.
      repository.currentResult = activatedRemoteSession;
      repository.closeResult = closeUnreachable;

      await sync();

      expect(bloc.state, endedUnconfirmed);
      // One more close for that read, and no more: no retry loop.
      expect(repository.closeCount, 2);
      expect(repository.closedIds, [testRemoteSessionId, testRemoteSessionId]);
    });

    test('once the backend accepts it, the end is confirmed', () async {
      await endWhileUnreachable();
      repository.currentQueue.addAll([activatedRemoteSession, noRemoteSession]);
      repository.closeResult = const Ok(closedSession);

      await sync();

      expect(bloc.state, const RemoteSessionIdle());
      expect(store.value, isNull);
    });

    test(
      'a /current that no longer has it confirms the end by itself',
      () async {
        await endWhileUnreachable();
        // The technician closed it meanwhile, or the backend finally got ours.
        repository.currentResult = noRemoteSession;

        await sync();

        expect(bloc.state, const RemoteSessionIdle());
        expect(store.value, isNull);
        expect(repository.closeCount, 1);
      },
    );

    test('a 409 on the repeat, with the session gone, confirms it', () async {
      await endWhileUnreachable();
      repository.currentQueue.addAll([activatedRemoteSession, noRemoteSession]);
      repository.closeResult = closeConflict;

      await sync();

      expect(
        bloc.state,
        const RemoteSessionIdle(lastFailure: ConflictFailure()),
      );
      expect(store.value, isNull);
    });

    test(
      'a CONNECTING read of the same session is refused just the same',
      () async {
        await endWhileUnreachable();
        repository.currentResult = connectingRemoteSession;

        await sync();

        expect(bloc.state, isA<RemoteSessionEndedLocally>());
      },
    );
  });

  group('Case D — late realtime events', () {
    test('remote-session:active for the ended session is ignored', () async {
      await endWhileUnreachable();
      repository.currentResult = activatedRemoteSession;
      final reads = repository.currentCount;

      bloc.add(const RemoteSessionActivationAnnounced(testRemoteSessionId));
      await settle();

      expect(bloc.state, endedUnconfirmed);
      expect(repository.currentCount, reads);
    });

    test('remote-session:active arriving while the close is in flight '
        'changes nothing', () async {
      await reachActive();
      final gate = Completer<void>();
      repository.closeGate = gate;
      repository.closeResult = closeUnreachable;

      bloc.add(const RemoteSessionCloseRequested());
      await settle();
      bloc
        ..add(const RemoteSessionActivationAnnounced(testRemoteSessionId))
        ..add(const RemoteSessionAnnounced(testRemoteSessionId))
        ..add(const RemoteSessionSyncRequested());
      await settle();
      gate.complete();
      await settle();

      expect(bloc.state, endedUnconfirmed);
    });

    test('a read already in flight when FINALIZAR is pressed cannot revive '
        'it', () async {
      await reachActive();
      // A read starts — a reconnection, say — and FINALIZAR is pressed while
      // it is out. Its answer, ACTIVE, arrives after the end.
      repository.currentResult = activatedRemoteSession;
      repository.closeResult = closeUnreachable;
      bloc
        ..add(const RemoteSessionSyncRequested())
        ..add(const RemoteSessionCloseRequested());
      await settle();

      expect(bloc.state, isA<RemoteSessionEndedLocally>());
      expect(
        (bloc.state as RemoteSessionEndedLocally).remoteSessionId,
        testRemoteSessionId,
      );
    });

    test(
      'remote-session:created for the ended session does not revive it',
      () async {
        await endWhileUnreachable();
        repository.currentResult = activatedRemoteSession;

        bloc.add(const RemoteSessionAnnounced(testRemoteSessionId));
        await settle();

        expect(bloc.state, endedUnconfirmed);
      },
    );
  });

  group('Case F — FINALIZAR twice', () {
    test('two presses end once and close once', () async {
      await reachActive();
      final gate = Completer<void>();
      repository.closeGate = gate;

      bloc
        ..add(const RemoteSessionCloseRequested())
        ..add(const RemoteSessionCloseRequested());
      await settle();
      bloc.add(const RemoteSessionCloseRequested());
      await settle();
      gate.complete();
      await settle();

      expect(repository.closeCount, 1);
      expect(store.calls.whereType<(String, String)>().toList(), [
        ('write', testRemoteSessionId),
      ]);
    });

    test(
      'REINTENTAR after a failure sends the close again, and only that',
      () async {
        await endWhileUnreachable();
        repository.closeResult = const Ok(closedSession);
        repository.currentResult = noRemoteSession;

        bloc.add(const RemoteSessionCloseRequested());
        await settle();

        expect(repository.closeCount, 2);
        expect(bloc.state, const RemoteSessionIdle());
      },
    );

    test('REINTENTAR that fails again stays ended', () async {
      await endWhileUnreachable();

      bloc.add(const RemoteSessionCloseRequested());
      await settle();

      expect(repository.closeCount, 2);
      expect(bloc.state, endedUnconfirmed);
    });
  });

  group('Case G — the application is killed and opened again', () {
    test('a session ended before the restart is not resumed', () async {
      await endWhileUnreachable();
      await bloc.close();

      // A new process: nothing in memory, only the store survives.
      bloc = build();
      repository.currentResult = activatedRemoteSession;
      repository.closeResult = closeUnreachable;
      await sync();

      expect(bloc.state, endedUnconfirmed);
      expect(store.value, testRemoteSessionId);
    });

    test('and the first read that reaches the backend confirms it', () async {
      await endWhileUnreachable();
      await bloc.close();

      bloc = build();
      repository.currentQueue.addAll([activatedRemoteSession, noRemoteSession]);
      repository.closeResult = const Ok(closedSession);
      await sync();

      expect(bloc.state, const RemoteSessionIdle());
      expect(store.value, isNull);
    });

    test('a dropped identity does not forget it either', () async {
      await endWhileUnreachable();

      bloc.add(const RemoteSessionResetRequested());
      await settle();
      expect(bloc.state, const RemoteSessionInitial());
      // Enrolled again, the backend may still hold the session live.
      repository.currentResult = activatedRemoteSession;
      await sync();

      expect(bloc.state, endedUnconfirmed);
      expect(store.value, testRemoteSessionId);
    });

    test('a store that cannot be written does not stop the end here', () async {
      store.failing = true;

      await endWhileUnreachable();

      // The restart guarantee is lost; the local revocation is not.
      expect(bloc.state, endedUnconfirmed);
      repository.currentResult = activatedRemoteSession;
      await sync();
      expect(bloc.state, endedUnconfirmed);
    });
  });

  group('Case H — a new assistance', () {
    test('a different session reaches live through the normal path', () async {
      await reachActive();
      repository.currentQueue.add(noRemoteSession);
      bloc.add(const RemoteSessionCloseRequested());
      await settle();
      expect(bloc.state, const RemoteSessionIdle());

      // A new request, accepted by the user, and a new session for it.
      repository.currentResult = const Ok<RemoteSession?>(
        RemoteSession(
          id: testOtherRemoteSessionId,
          supportRequestId: testSupportRequestId,
          status: RemoteSessionStatus.active,
          technician: testRemoteSessionTechnician,
        ),
      );
      await sync();

      expect(bloc.state, isA<RemoteSessionActive>());
      expect(
        (bloc.state as RemoteSessionActive).session.id,
        testOtherRemoteSessionId,
      );
    });

    test('a different session read while the end is unconfirmed confirms it '
        'and is adopted', () async {
      // The backend allows one live session per device, so a different live
      // one says the ended one is gone — and it exists only because the user
      // accepted a new request for it.
      await endWhileUnreachable();
      repository.currentResult = const Ok<RemoteSession?>(
        RemoteSession(
          id: testOtherRemoteSessionId,
          supportRequestId: testSupportRequestId,
          status: RemoteSessionStatus.connecting,
          technician: testRemoteSessionTechnician,
        ),
      );

      await sync();

      expect(bloc.state, isA<RemoteSessionConnecting>());
      expect(store.value, isNull);
    });
  });
}
