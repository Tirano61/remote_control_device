import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_ended_by.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';

import '../../../fakes/manual_timers.dart';
import '../../../fakes/remote_session_fakes.dart';

/// C2: a session the backend may have closed must not keep its authority on
/// the tablet just because the tablet could not hear about it.
///
/// ```text
/// confirmed   channel up + a read started after it came up said live
/// suspended   anything else          -> no command runs
/// expired     suspended for the whole grace period -> ended here
/// ```
///
/// Every deadline runs on [ManualTimers].
void main() {
  const grace = RemoteSessionBloc.defaultAuthorityGracePeriod;

  late FakeRemoteSessionRepository repository;
  late FakeEndedRemoteSessionStore endedSessionStore;
  late ManualTimers timers;
  late RemoteSessionBloc bloc;

  RemoteSessionBloc build() => RemoteSessionBloc(
    loadCurrentRemoteSession: LoadCurrentRemoteSession(repository),
    closeRemoteSession: CloseRemoteSession(repository),
    endedSessionStore: endedSessionStore,
    timerFactory: timers.factory,
  );

  setUp(() {
    repository = FakeRemoteSessionRepository();
    endedSessionStore = FakeEndedRemoteSessionStore();
    timers = ManualTimers();
    bloc = build();
  });

  tearDown(() async => bloc.close());

  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> channel({required bool up}) async {
    bloc.add(RemoteSessionAuthorityChannelChanged(available: up));
    await settle();
  }

  Future<void> sync() async {
    bloc.add(const RemoteSessionSyncRequested());
    await settle();
  }

  /// Socket up, `/current` says ACTIVE: commands may run.
  Future<void> reachConfirmedActive() async {
    await channel(up: true);
    repository.currentResult = activatedRemoteSession;
    await sync();
    expect(
      bloc.state,
      isA<RemoteSessionActive>().having(
        (s) => s.authority,
        'authority',
        RemoteSessionAuthority.confirmed,
      ),
    );
  }

  RemoteSessionAuthority? authorityOf(RemoteSessionState state) =>
      state is RemoteSessionLive ? state.authority : null;

  group('authority', () {
    test('a read made before the channel is up confirms nothing', () async {
      repository.currentResult = activatedRemoteSession;
      await sync();

      expect(bloc.state, isA<RemoteSessionActive>());
      expect(authorityOf(bloc.state), RemoteSessionAuthority.suspended);
    });

    test('losing the channel suspends at once, without a read', () async {
      await reachConfirmedActive();
      final reads = repository.currentCount;

      bloc.add(const RemoteSessionAuthorityChannelChanged(available: false));
      // Handled synchronously: the next microtask already sees it.
      await Future<void>.delayed(Duration.zero);

      expect(authorityOf(bloc.state), RemoteSessionAuthority.suspended);
      expect(repository.currentCount, reads);
      // Still the same live session: nothing is torn down by this alone.
      expect(
        (bloc.state as RemoteSessionActive).session.id,
        testRemoteSessionId,
      );
    });

    test(
      'the channel coming back confirms nothing until a fresh read',
      () async {
        await reachConfirmedActive();
        await channel(up: false);
        await channel(up: true);

        expect(authorityOf(bloc.state), RemoteSessionAuthority.suspended);

        await sync();
        expect(authorityOf(bloc.state), RemoteSessionAuthority.confirmed);
      },
    );

    test('a failed read never confirms, and never conserves authority it '
        'did not have', () async {
      await reachConfirmedActive();
      await channel(up: false);
      await channel(up: true);
      repository.currentResult = remoteSessionUnreachable;

      await sync();

      expect(bloc.state, isA<RemoteSessionActive>());
      expect(authorityOf(bloc.state), RemoteSessionAuthority.suspended);
    });

    test('a 401 during reconciliation is no confirmation either', () async {
      await reachConfirmedActive();
      await channel(up: false);
      await channel(up: true);
      repository.currentResult = const Err<RemoteSession?>(AuthFailure());

      await sync();

      expect(authorityOf(bloc.state), RemoteSessionAuthority.suspended);
    });

    test(
      'a read in flight when the channel dropped cannot restore it',
      () async {
        await reachConfirmedActive();
        final gate = repository.currentGate = Completer<void>();
        bloc.add(const RemoteSessionSyncRequested());
        await settle();

        // The socket drops and comes back while that read is on the wire.
        await channel(up: false);
        await channel(up: true);
        gate.complete();
        await settle();

        expect(authorityOf(bloc.state), RemoteSessionAuthority.suspended);
      },
    );

    test('a read started while the channel was down cannot confirm after it '
        'is back', () async {
      await reachConfirmedActive();
      await channel(up: false);
      final gate = repository.currentGate = Completer<void>();
      bloc.add(const RemoteSessionSyncRequested());
      await settle();

      await channel(up: true);
      gate.complete();
      await settle();

      expect(authorityOf(bloc.state), RemoteSessionAuthority.suspended);
      repository.currentGate = null;
      await sync();
      expect(authorityOf(bloc.state), RemoteSessionAuthority.confirmed);
    });
  });

  group('grace period', () {
    test(
      'reconnecting and reconciling inside it keeps the assistance',
      () async {
        await reachConfirmedActive();
        await channel(up: false);
        timers.elapse(grace - const Duration(seconds: 1));
        await settle();

        await channel(up: true);
        await sync();
        timers.elapse(grace * 2);
        await settle();

        expect(bloc.state, isA<RemoteSessionActive>());
        expect(authorityOf(bloc.state), RemoteSessionAuthority.confirmed);
        expect(repository.closeCount, 0);
      },
    );

    test('running out ends it here, irreversibly, without sending the close '
        'the user did not ask for', () async {
      await reachConfirmedActive();
      repository.currentResult = remoteSessionUnreachable;
      await channel(up: false);

      timers.elapse(grace - const Duration(milliseconds: 1));
      await settle();
      expect(bloc.state, isA<RemoteSessionActive>());

      timers.elapse(const Duration(milliseconds: 1));
      await settle();

      expect(
        bloc.state,
        isA<RemoteSessionEndedLocally>()
            .having((s) => s.remoteSessionId, 'id', testRemoteSessionId)
            .having(
              (s) => s.reason,
              'reason',
              RemoteSessionLocalEndReason.authorityLost,
            )
            // Nothing is being sent: the backend closes it as SYSTEM.
            .having((s) => s.confirming, 'confirming', isFalse),
      );
      expect(endedSessionStore.value, testRemoteSessionId);
      expect(endedSessionStore.closeOwed, isFalse);
      expect(repository.closedIds, isEmpty);
    });

    test('a reconnection whose read fails does not buy more time', () async {
      await reachConfirmedActive();
      repository.closeResult = closeUnreachable;
      await channel(up: false);
      timers.elapse(grace ~/ 2);
      await settle();

      await channel(up: true);
      repository.currentResult = remoteSessionUnreachable;
      await sync();
      timers.elapse(grace ~/ 2);
      await settle();

      expect(bloc.state, isA<RemoteSessionEndedLocally>());
    });

    test('a socket that flaps does not restart the clock', () async {
      await reachConfirmedActive();
      // Every re-read fails: only a read could have confirmed it.
      repository.currentResult = remoteSessionUnreachable;
      for (var i = 0; i < 4; i++) {
        await channel(up: false);
        timers.elapse(grace ~/ 5);
        await channel(up: true);
      }
      timers.elapse(grace ~/ 5);
      await settle();

      expect(bloc.state, isA<RemoteSessionEndedLocally>());
    });

    test('reconnecting after it ran out finds the session ended; the backend '
        'still holding it ACTIVE gets no close, and its own close confirms '
        'it', () async {
      await reachConfirmedActive();
      repository.currentResult = remoteSessionUnreachable;
      await channel(up: false);
      timers.elapse(grace);
      await settle();

      // The backend's grace is still running: it still says ACTIVE.
      repository.currentResult = activatedRemoteSession;
      await channel(up: true);
      await sync();
      expect(bloc.state, isA<RemoteSessionEndedLocally>());
      expect(repository.closeCount, 0);

      // It closes the session itself (SYSTEM), and says so.
      repository.currentResult = noRemoteSession;
      bloc.add(
        const RemoteSessionClosureAnnounced(
          testRemoteSessionId,
          endedBy: RemoteSessionEndedBy.system,
        ),
      );
      await settle();

      expect(repository.closeCount, 0);
      expect(bloc.state, const RemoteSessionIdle(interrupted: true));
      expect(endedSessionStore.value, isNull);
    });

    test(
      'a session closed by SYSTEM meanwhile is simply over on return',
      () async {
        await reachConfirmedActive();
        await channel(up: false);
        timers.elapse(grace ~/ 3);

        repository.currentResult = noRemoteSession;
        await channel(up: true);
        await sync();

        // Nobody said who closed it, and it went while the tablet could not
        // confirm it: a connection problem, never a FINALIZAR.
        expect(bloc.state, const RemoteSessionIdle(interrupted: true));
        timers.elapse(grace * 2);
        await settle();
        expect(repository.closeCount, 0);
        expect(timers.pending, isEmpty);
      },
    );

    test(
      'REST returning a different session does not carry anything over',
      () async {
        await reachConfirmedActive();
        await channel(up: false);
        repository.currentResult = Ok<RemoteSession?>(
          RemoteSession(
            id: testOtherRemoteSessionId,
            supportRequestId: activatedSession.supportRequestId,
            status: activatedSession.status,
            technician: activatedSession.technician,
          ),
        );
        await channel(up: true);
        await sync();

        final state = bloc.state as RemoteSessionActive;
        expect(state.session.id, testOtherRemoteSessionId);
        expect(timers.pending, isEmpty);
      },
    );
  });

  group('remote-session:closed', () {
    test('SYSTEM withdraws at once, before the read answers', () async {
      await reachConfirmedActive();
      final gate = repository.currentGate = Completer<void>();
      repository.currentResult = noRemoteSession;

      bloc.add(
        const RemoteSessionClosureAnnounced(
          testRemoteSessionId,
          endedBy: RemoteSessionEndedBy.system,
        ),
      );
      await settle();

      expect(
        bloc.state,
        const RemoteSessionClosedRemotely(
          testRemoteSessionId,
          endedBy: RemoteSessionEndedBy.system,
        ),
      );
      gate.complete();
      await settle();
      expect(
        bloc.state,
        const RemoteSessionIdle(lastClosure: RemoteSessionEndedBy.system),
      );
    });

    test(
      'a read already in flight that says ACTIVE cannot revive it',
      () async {
        await reachConfirmedActive();
        final gate = repository.currentGate = Completer<void>();
        bloc.add(const RemoteSessionSyncRequested());
        await settle();

        bloc.add(
          const RemoteSessionClosureAnnounced(
            testRemoteSessionId,
            endedBy: RemoteSessionEndedBy.system,
          ),
        );
        await settle();
        gate.complete();
        await settle();

        expect(bloc.state, isA<RemoteSessionClosedRemotely>());
      },
    );

    test(
      'nothing later revives it: activation, reconnection, re-reads',
      () async {
        await reachConfirmedActive();
        bloc.add(const RemoteSessionClosureAnnounced(testRemoteSessionId));
        await settle();

        bloc.add(const RemoteSessionActivationAnnounced(testRemoteSessionId));
        await channel(up: false);
        await channel(up: true);
        await sync();
        await sync();

        expect(bloc.state, isA<RemoteSessionClosedRemotely>());
        expect(timers.pending, isEmpty);
      },
    );

    test('while suspended, it still withdraws (and stops the clock)', () async {
      await reachConfirmedActive();
      await channel(up: false);
      // The grace period and the first re-read.
      expect(timers.pending, hasLength(2));

      bloc.add(
        const RemoteSessionClosureAnnounced(
          testRemoteSessionId,
          endedBy: RemoteSessionEndedBy.system,
        ),
      );
      await settle();

      expect(bloc.state, isA<RemoteSessionClosedRemotely>());
      expect(timers.pending, isEmpty);
    });

    test('repeated closures are idempotent', () async {
      await reachConfirmedActive();
      repository.currentResult = noRemoteSession;
      for (var i = 0; i < 3; i++) {
        bloc.add(const RemoteSessionClosureAnnounced(testRemoteSessionId));
      }
      await settle();

      expect(bloc.state, isA<RemoteSessionIdle>());
      expect(repository.closeCount, 0);
    });

    test('a closure naming another session withdraws nothing held', () async {
      await reachConfirmedActive();
      bloc.add(const RemoteSessionClosureAnnounced(testOtherRemoteSessionId));
      await settle();

      expect(bloc.state, isA<RemoteSessionActive>());
      expect(authorityOf(bloc.state), RemoteSessionAuthority.confirmed);
    });
  });

  group('FINALIZAR (Prompt 29) is unaffected', () {
    test(
      'a session ended here stays ended across suspension and return',
      () async {
        await reachConfirmedActive();
        repository.closeResult = closeUnreachable;
        bloc.add(const RemoteSessionCloseRequested());
        await settle();

        await channel(up: false);
        timers.elapse(grace * 2);
        await channel(up: true);
        await sync();

        final state = bloc.state as RemoteSessionEndedLocally;
        expect(state.reason, RemoteSessionLocalEndReason.userRequest);
        expect(endedSessionStore.value, testRemoteSessionId);
      },
    );

    test('after a restart, the marker still refuses the session, and an '
        'expired one is refused like it', () async {
      await reachConfirmedActive();
      repository.closeResult = closeUnreachable;
      await channel(up: false);
      timers.elapse(grace);
      await settle();
      expect(endedSessionStore.value, testRemoteSessionId);
      await bloc.close();

      // A new process: same store, backend still says ACTIVE.
      timers = ManualTimers();
      bloc = build();
      repository.currentResult = activatedRemoteSession;
      await channel(up: true);
      await sync();

      expect(bloc.state, isA<RemoteSessionEndedLocally>());
    });
  });
}
