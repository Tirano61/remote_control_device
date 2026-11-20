import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_ended_by.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';

import '../../../fakes/remote_session_fakes.dart';
import '../../../fakes/support_fakes.dart';

/// The idempotent close contract (remote_control_backend f5b8a1c, Prompt 39).
///
/// `POST /device/remote-sessions/:id/close` on a session of this device that
/// is already `CLOSED` answers `200` with the *original* close — `endedAt` and
/// `endedBy` as the first close left them, whoever made it. `404` is a session
/// that is not this device's; `409` only a live session whose request cannot
/// complete.
///
/// What the tablet must make of it:
///
/// ```text
/// 200, same id, CLOSED, endedAt   confirmed, whatever endedBy says
/// any other 200                   not a confirmation; /current decides
/// 404 / 409 / 5xx / timeout       not a confirmation; never live again
/// ```
///
/// Numbers are those of the Prompt 39 test list.
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
    bloc.add(const RemoteSessionAuthorityChannelChanged(available: true));
    repository.currentResult = activatedRemoteSession;
    await sync();
    expect(bloc.state, isA<RemoteSessionActive>());
  }

  Future<void> finalizar() async {
    bloc.add(const RemoteSessionCloseRequested());
    await settle();
  }

  /// FINALIZAR whose answer never arrives — the request may or may not have
  /// reached the backend.
  Future<void> finalizarResponseLost() async {
    await reachActive();
    repository.closeResult = closeUnreachable;
    await finalizar();
    expect(
      bloc.state,
      const RemoteSessionEndedLocally(
        testRemoteSessionId,
        lastFailure: NetworkFailure(),
      ),
    );
    expect(store.value, testRemoteSessionId);
  }

  RemoteSession liveOther(RemoteSessionStatus status) => RemoteSession(
    id: testOtherRemoteSessionId,
    supportRequestId: testSupportRequestId,
    status: status,
    technician: testRemoteSessionTechnician,
  );

  group('RemoteSession.confirmsCloseOf', () {
    test('same id, CLOSED and endedAt: yes, whoever closed it', () {
      for (final endedBy in [...RemoteSessionEndedBy.values, null]) {
        expect(
          closedSessionBy(endedBy).confirmsCloseOf(testRemoteSessionId),
          isTrue,
          reason: '$endedBy',
        );
      }
    });

    test('another id, a live or unknown status, or no endedAt: no', () {
      expect(
        closedSessionBy(
          RemoteSessionEndedBy.device,
          id: testOtherRemoteSessionId,
        ).confirmsCloseOf(testRemoteSessionId),
        isFalse,
      );
      for (final session in [connectingSession, activeSession]) {
        expect(session.confirmsCloseOf(testRemoteSessionId), isFalse);
      }
      expect(
        RemoteSession(
          id: testRemoteSessionId,
          supportRequestId: testSupportRequestId,
          status: RemoteSessionStatus.unknown,
          endedAt: DateTime.parse(testEndedAtWire),
        ).confirmsCloseOf(testRemoteSessionId),
        isFalse,
      );
      expect(
        closedSessionBy(
          RemoteSessionEndedBy.device,
          withEndedAt: false,
        ).confirmsCloseOf(testRemoteSessionId),
        isFalse,
      );
    });
  });

  group('a 200 that confirms', () {
    test('1. the first close: ended at once, confirmed, marker cleared, one '
        'close', () async {
      await reachActive();
      final gate = Completer<void>();
      repository.closeGate = gate;
      repository.closeResult = Ok(closedSessionBy(RemoteSessionEndedBy.device));
      repository.currentResult = noRemoteSession;

      await finalizar();
      expect(
        bloc.state,
        const RemoteSessionEndedLocally(testRemoteSessionId, confirming: true),
      );
      expect(store.value, testRemoteSessionId);

      gate.complete();
      await settle();

      expect(bloc.state, const RemoteSessionIdle());
      expect(store.value, isNull);
      expect(repository.closedIds, [testRemoteSessionId]);
    });

    for (final (number, endedBy) in [
      ('3', RemoteSessionEndedBy.device),
      ('4', RemoteSessionEndedBy.technician),
      ('5', RemoteSessionEndedBy.system),
      ('-', RemoteSessionEndedBy.unknown),
    ]) {
      test('$number. a 200 with endedBy ${endedBy.name} is a confirmation: '
          'DEVICE is never required', () async {
        await reachActive();
        repository.closeResult = Ok(closedSessionBy(endedBy));
        repository.currentResult = noRemoteSession;

        await finalizar();

        expect(bloc.state, const RemoteSessionIdle());
        expect(store.value, isNull);
        // Nothing else goes to the backend: one close, then the contract's
        // recovery read.
        expect(repository.closeCount, 1);
        expect(repository.currentCount, 2);
      });
    }

    test('2/7. the repeat after a lost response answers 200 DEVICE and '
        'confirms it, addressed to the same id', () async {
      await finalizarResponseLost();
      // The first POST had reached the backend: the repeat answers the
      // original close.
      repository.closeResult = Ok(closedSessionBy(RemoteSessionEndedBy.device));
      repository.currentResult = noRemoteSession;

      // REINTENTAR.
      await finalizar();

      expect(bloc.state, const RemoteSessionIdle());
      expect(store.value, isNull);
      expect(repository.closedIds, [testRemoteSessionId, testRemoteSessionId]);
    });

    test('6. a lost response, then /current without the session: confirmed '
        'with no second close', () async {
      await finalizarResponseLost();
      repository.currentResult = noRemoteSession;

      // The socket coming back, for instance.
      await sync();

      expect(bloc.state, const RemoteSessionIdle());
      expect(store.value, isNull);
      expect(repository.closeCount, 1);
    });

    test('a repeat on reconnection, with /current still ACTIVE (the first '
        'POST never arrived), confirms on the 200', () async {
      await finalizarResponseLost();
      repository.currentQueue.addAll([activatedRemoteSession, noRemoteSession]);
      repository.closeResult = Ok(closedSessionBy(RemoteSessionEndedBy.device));

      await sync();

      expect(bloc.state, const RemoteSessionIdle());
      expect(store.value, isNull);
      expect(repository.closeCount, 2);
    });
  });

  group('a 200 that does not confirm', () {
    test('8. a CLOSED session with another id: the marker of this one stays, '
        'and it stays ended', () async {
      await reachActive();
      repository.closeResult = Ok(
        closedSessionBy(
          RemoteSessionEndedBy.device,
          id: testOtherRemoteSessionId,
        ),
      );
      // The backend still holds this session live.
      repository.currentResult = activatedRemoteSession;

      await finalizar();

      expect(
        bloc.state,
        const RemoteSessionEndedLocally(
          testRemoteSessionId,
          lastFailure: ServerFailure(),
        ),
      );
      expect(store.value, testRemoteSessionId);
      // One close, one read: no second close for the same cue.
      expect(repository.closeCount, 1);
      expect(repository.currentCount, 2);
    });

    test('8b. a live session with another id in the body is never adopted '
        'from the close answer', () async {
      await reachActive();
      final gate = Completer<void>();
      repository.closeGate = gate;
      repository.closeResult = Ok(liveOther(RemoteSessionStatus.active));
      final seen = <RemoteSessionState>[];
      final subscription = bloc.stream.listen(seen.add);
      repository.currentResult = activatedRemoteSession;

      await finalizar();
      gate.complete();
      await settle();
      await subscription.cancel();

      expect(
        seen.whereType<RemoteSessionLive>(),
        isEmpty,
        reason: 'nothing live is emitted after FINALIZAR',
      );
      expect(bloc.state, isA<RemoteSessionEndedLocally>());
      expect(store.value, testRemoteSessionId);
    });

    test(
      '9. the same id still ACTIVE: stays ended, marker kept, no loop',
      () async {
        await reachActive();
        repository.closeResult = const Ok(activeSession);
        repository.currentResult = activatedRemoteSession;

        await finalizar();

        expect(
          bloc.state,
          const RemoteSessionEndedLocally(
            testRemoteSessionId,
            lastFailure: ServerFailure(),
          ),
        );
        expect(store.value, testRemoteSessionId);
        expect(repository.closeCount, 1);
      },
    );

    test(
      '10. CLOSED without endedAt: not a confirmation, marker kept',
      () async {
        await reachActive();
        repository.closeResult = Ok(
          closedSessionBy(RemoteSessionEndedBy.device, withEndedAt: false),
        );
        repository.currentResult = activatedRemoteSession;

        await finalizar();

        expect(bloc.state, isA<RemoteSessionEndedLocally>());
        expect(store.value, testRemoteSessionId);
        expect(repository.closeCount, 1);
      },
    );

    test('10b. a non-confirming 200 followed by /current without the session '
        'is confirmed by /current', () async {
      await reachActive();
      repository.closeResult = Ok(
        closedSessionBy(RemoteSessionEndedBy.device, withEndedAt: false),
      );
      repository.currentResult = noRemoteSession;

      await finalizar();

      expect(bloc.state, const RemoteSessionIdle(lastFailure: ServerFailure()));
      expect(store.value, isNull);
    });

    test('the next cue after a non-confirming 200 sends one close, and a '
        'proper 200 confirms it', () async {
      await reachActive();
      repository.closeResult = const Ok(activeSession);
      repository.currentResult = activatedRemoteSession;
      await finalizar();

      repository.closeResult = Ok(closedSessionBy(RemoteSessionEndedBy.device));
      repository.currentQueue.add(activatedRemoteSession);
      repository.currentResult = noRemoteSession;
      await sync();

      expect(bloc.state, const RemoteSessionIdle());
      expect(store.value, isNull);
      expect(repository.closeCount, 2);
    });
  });

  group('errors', () {
    test('11. 404 with the session gone from /current: confirmed by the '
        'read', () async {
      await reachActive();
      repository.closeResult = closeNotFound;
      repository.currentResult = noRemoteSession;

      await finalizar();

      expect(
        bloc.state,
        const RemoteSessionIdle(lastFailure: NotFoundFailure()),
      );
      expect(store.value, isNull);
    });

    test(
      '11b. 404 with the session still live in /current: stays ended',
      () async {
        await reachActive();
        repository.closeResult = closeNotFound;
        repository.currentResult = activatedRemoteSession;

        await finalizar();

        expect(
          bloc.state,
          const RemoteSessionEndedLocally(
            testRemoteSessionId,
            lastFailure: NotFoundFailure(),
          ),
        );
        expect(store.value, testRemoteSessionId);
        expect(repository.closeCount, 1);
      },
    );

    test('12. 409 on a live session: stays ended, marker kept, one close per '
        'cue', () async {
      await reachActive();
      repository.closeResult = closeConflict;
      // The only 409 left: the session is live, its request cannot complete.
      repository.currentResult = activatedRemoteSession;

      await finalizar();

      expect(
        bloc.state,
        const RemoteSessionEndedLocally(
          testRemoteSessionId,
          lastFailure: ConflictFailure(),
        ),
      );
      expect(store.value, testRemoteSessionId);
      expect(repository.closeCount, 1);

      // The next cue tells the backend again, once.
      await sync();
      expect(repository.closeCount, 2);
      expect(bloc.state, isA<RemoteSessionEndedLocally>());
    });

    for (final (number, name, failure) in [
      ('13', 'HTTP 500', const ServerFailure()),
      ('14', 'a timeout', const NetworkFailure()),
    ]) {
      test('$number. $name keeps it ended and the marker pending', () async {
        await reachActive();
        repository.closeResult = Err<RemoteSession>(failure);

        await finalizar();

        expect(
          bloc.state,
          RemoteSessionEndedLocally(testRemoteSessionId, lastFailure: failure),
        );
        expect(store.value, testRemoteSessionId);
        // No retry of its own: the next cue does that.
        expect(repository.closeCount, 1);
      });
    }
  });

  group('other ends', () {
    test('18. a SYSTEM close announced while the POST is pending, then the '
        '200 SYSTEM: one close, confirmed', () async {
      await reachActive();
      final gate = Completer<void>();
      repository.closeGate = gate;
      repository.closeResult = Ok(closedSessionBy(RemoteSessionEndedBy.system));
      repository.currentResult = noRemoteSession;

      await finalizar();
      bloc.add(
        const RemoteSessionClosureAnnounced(
          testRemoteSessionId,
          endedBy: RemoteSessionEndedBy.system,
        ),
      );
      await settle();
      // The local end stands while the close is in flight.
      expect(
        bloc.state,
        const RemoteSessionEndedLocally(testRemoteSessionId, confirming: true),
      );

      gate.complete();
      await settle();

      expect(bloc.state, const RemoteSessionIdle());
      expect(store.value, isNull);
      expect(repository.closeCount, 1);
    });

    test('a TECHNICIAN close announced first: FINALIZAR has nothing to end '
        'and sends no close', () async {
      await reachActive();
      repository.currentResult = noRemoteSession;
      bloc.add(
        const RemoteSessionClosureAnnounced(
          testRemoteSessionId,
          endedBy: RemoteSessionEndedBy.technician,
        ),
      );
      await settle();

      await finalizar();

      expect(
        bloc.state,
        const RemoteSessionIdle(lastClosure: RemoteSessionEndedBy.technician),
      );
      expect(repository.closeCount, 0);
    });

    test('the response of a close that lost the connection arrives after a '
        'SYSTEM close: it cannot revive anything', () async {
      await reachActive();
      final gate = Completer<void>();
      repository.closeGate = gate;
      repository.closeResult = closeUnreachable;

      await finalizar();
      bloc.add(
        const RemoteSessionClosureAnnounced(
          testRemoteSessionId,
          endedBy: RemoteSessionEndedBy.system,
        ),
      );
      await settle();
      repository.currentResult = activatedRemoteSession; // a stale read
      gate.complete();
      await settle();
      await sync();

      expect(bloc.state, isA<RemoteSessionEndedLocally>());
    });
  });

  group('restart', () {
    test('17. a close pending across a restart is sent once and confirmed by '
        'a 200 that says TECHNICIAN', () async {
      await finalizarResponseLost();
      await bloc.close();

      // The application is opened again; the backend still has it live.
      bloc = build();
      bloc.add(const RemoteSessionAuthorityChannelChanged(available: true));
      repository.currentQueue.add(activatedRemoteSession);
      repository.currentResult = noRemoteSession;
      // Meanwhile the technician closed it.
      repository.closeResult = Ok(
        closedSessionBy(RemoteSessionEndedBy.technician),
      );

      await sync();

      expect(bloc.state, const RemoteSessionIdle());
      expect(store.value, isNull);
      expect(repository.closedIds, [testRemoteSessionId, testRemoteSessionId]);
    });

    test('19. a session ended for lost authority owes no close: a restart '
        'with it still live sends none', () async {
      store
        ..value = testRemoteSessionId
        ..closeOwed = false;
      bloc.add(const RemoteSessionAuthorityChannelChanged(available: true));
      repository.currentResult = activatedRemoteSession;

      await sync();
      await finalizar(); // even pressed again

      expect(bloc.state, isA<RemoteSessionEndedLocally>());
      expect(repository.closeCount, 0);
      expect(store.value, testRemoteSessionId);
    });
  });

  group('20. a new assistance', () {
    test('after a confirmed close, a new session is adopted normally and no '
        'close ever addresses it', () async {
      await reachActive();
      repository.currentResult = noRemoteSession;
      await finalizar();
      expect(bloc.state, const RemoteSessionIdle());

      repository.currentResult = Ok<RemoteSession?>(
        liveOther(RemoteSessionStatus.connecting),
      );
      await sync();

      expect(bloc.state, isA<RemoteSessionConnecting>());
      expect(
        (bloc.state as RemoteSessionConnecting).session.id,
        testOtherRemoteSessionId,
      );
      expect(repository.closedIds, [testRemoteSessionId]);
    });

    test('a late non-confirming 200 for the old session leaves a new one '
        'untouched', () async {
      await reachActive();
      final gate = Completer<void>();
      repository.closeGate = gate;
      // Anomalous: the old close answers with the new session in the body.
      repository.closeResult = Ok(liveOther(RemoteSessionStatus.active));
      await finalizar();

      // The backend already moved on: the old one is gone, a new one exists.
      repository.currentResult = Ok<RemoteSession?>(
        liveOther(RemoteSessionStatus.connecting),
      );
      gate.complete();
      await settle();

      // The new session arrived through /current, not through the close
      // answer, and only as CONNECTING: nothing was granted by the 200.
      expect(bloc.state, isA<RemoteSessionConnecting>());
      expect(
        (bloc.state as RemoteSessionConnecting).session.id,
        testOtherRemoteSessionId,
      );
      expect(repository.closedIds, [testRemoteSessionId]);
      expect(store.value, isNull);
    });
  });
}
