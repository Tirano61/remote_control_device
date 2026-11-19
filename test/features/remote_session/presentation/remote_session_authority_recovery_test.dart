import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';

import '../../../fakes/manual_timers.dart';
import '../../../fakes/remote_session_fakes.dart';

/// M1 (audit of Prompt 37): the tablet ending an assistance by itself while
/// the backend could still have kept it.
///
/// The backend keeps an `ACTIVE` session for 60 s after it notices the device
/// gone (`REMOTE_SESSION_DISCONNECT_GRACE_MS`). These tests put the tablet in
/// situations the backend would still accept and check that it does not give
/// up first, and that it never sends a close the user did not ask for.
void main() {
  /// The backend's default grace, as documented in REALTIME.md.
  const backendGrace = Duration(seconds: 60);

  late FakeRemoteSessionRepository repository;
  late FakeEndedRemoteSessionStore endedSessionStore;
  late ManualTimers timers;
  late RemoteSessionBloc bloc;

  setUp(() {
    repository = FakeRemoteSessionRepository();
    endedSessionStore = FakeEndedRemoteSessionStore();
    timers = ManualTimers();
    bloc = RemoteSessionBloc(
      loadCurrentRemoteSession: LoadCurrentRemoteSession(repository),
      closeRemoteSession: CloseRemoteSession(repository),
      endedSessionStore: endedSessionStore,
      timerFactory: timers.factory,
    );
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

  Future<void> elapse(Duration duration) async {
    timers.elapse(duration);
    await settle();
  }

  Future<void> reachConfirmedActive() async {
    await channel(up: true);
    repository.currentResult = activatedRemoteSession;
    await sync();
  }

  bool confirmed() =>
      bloc.state is RemoteSessionActive &&
      (bloc.state as RemoteSessionActive).authority ==
          RemoteSessionAuthority.confirmed;

  test('M1-a: one failed read after the socket is back is retried, and the '
      'assistance continues without any close', () async {
    await reachConfirmedActive();
    await channel(up: false);
    await elapse(const Duration(seconds: 10));

    // The socket returns; the read it causes hits a transient failure (the
    // dev tunnel answering 302 for a few seconds was seen on the T10A).
    repository.currentResult = remoteSessionUnreachable;
    await channel(up: true);
    await sync();
    expect(confirmed(), isFalse);

    // REST is back. No new socket event, no realtime notice.
    repository.currentResult = activatedRemoteSession;
    await elapse(const Duration(seconds: 20));

    expect(confirmed(), isTrue);
    expect(repository.closedIds, isEmpty);
  });

  test('M1-b: back after 50 s, inside the backend grace, the session is '
      'recovered rather than ended here', () async {
    await reachConfirmedActive();
    await channel(up: false);
    await elapse(const Duration(seconds: 50));

    await channel(up: true);
    await sync();

    expect(confirmed(), isTrue);
    expect(repository.closedIds, isEmpty);
  });

  group('policy', () {
    test('the grace is the backend grace plus 15 s', () {
      expect(
        RemoteSessionBloc.defaultAuthorityGracePeriod,
        RemoteSessionBloc.backendDisconnectGrace + const Duration(seconds: 15),
      );
      expect(RemoteSessionBloc.backendDisconnectGrace, backendGrace);
    });

    test('7. FINALIZAR during the recovery is the user\'s: ended at once, '
        'DEVICE close sent, never resumed', () async {
      await reachConfirmedActive();
      await channel(up: false);
      await elapse(const Duration(seconds: 20));

      // The backend, once it records the close, no longer returns it.
      repository.currentResult = noRemoteSession;
      bloc.add(const RemoteSessionCloseRequested());
      await settle();

      expect(repository.closedIds, [testRemoteSessionId]);
      expect(bloc.state, isA<RemoteSessionIdle>());
      expect(endedSessionStore.value, isNull);

      // A late reconnection that still reads ACTIVE resumes nothing.
      repository.currentResult = activatedRemoteSession;
      await channel(up: true);
      await sync();
      expect(bloc.state, isNot(isA<RemoteSessionLive>()));
      await elapse(backendGrace * 2);
      expect(timers.pending, isEmpty);
    });

    test('7b. FINALIZAR during the recovery with the backend unreachable is '
        'remembered as owing a close, and sent again on return', () async {
      await reachConfirmedActive();
      await channel(up: false);
      repository.closeResult = closeUnreachable;
      bloc.add(const RemoteSessionCloseRequested());
      await settle();
      expect(endedSessionStore.closeOwed, isTrue);

      repository.closeResult = const Ok(closedSession);
      repository.currentQueue.add(activatedRemoteSession);
      repository.currentResult = noRemoteSession;
      await channel(up: true);
      await sync();

      expect(repository.closedIds, [testRemoteSessionId, testRemoteSessionId]);
      expect(bloc.state, isA<RemoteSessionIdle>());
    });

    test('8. socket back with the read still pending: no retry is stacked on '
        'it, and its answer confirms', () async {
      await reachConfirmedActive();
      await channel(up: false);
      await channel(up: true);
      final reads = repository.currentCount;
      final gate = repository.currentGate = Completer<void>();
      bloc.add(const RemoteSessionSyncRequested());
      await settle();

      await elapse(const Duration(seconds: 30));
      expect(repository.currentCount, reads + 1);
      expect(confirmed(), isFalse);

      gate.complete();
      await settle();
      expect(confirmed(), isTrue);
      expect(repository.closedIds, isEmpty);
    });

    test('9. the grace runs out with a read on the wire: its late ACTIVE '
        'answer changes nothing', () async {
      await reachConfirmedActive();
      repository.currentResult = remoteSessionUnreachable;
      await channel(up: false);
      await elapse(
        RemoteSessionBloc.defaultAuthorityGracePeriod -
            const Duration(seconds: 1),
      );

      repository.currentResult = activatedRemoteSession;
      final gate = repository.currentGate = Completer<void>();
      await channel(up: true);
      await sync();
      await elapse(const Duration(seconds: 1));
      expect(bloc.state, isA<RemoteSessionEndedLocally>());

      gate.complete();
      await settle();
      expect(bloc.state, isA<RemoteSessionEndedLocally>());
      expect(repository.closedIds, isEmpty);
    });

    test('10. ending twice: the expiry and a later press send nothing and '
        'resume nothing', () async {
      await reachConfirmedActive();
      repository.currentResult = remoteSessionUnreachable;
      await channel(up: false);
      await elapse(RemoteSessionBloc.defaultAuthorityGracePeriod);
      final ended = bloc.state;
      expect(ended, isA<RemoteSessionEndedLocally>());

      bloc.add(const RemoteSessionCloseRequested());
      bloc.add(const RemoteSessionCloseRequested());
      await settle();
      await elapse(RemoteSessionBloc.defaultAuthorityGracePeriod);

      expect(bloc.state, isA<RemoteSessionEndedLocally>());
      expect(repository.closedIds, isEmpty);
    });

    test(
      '10b. FINALIZAR pressed twice during the recovery sends one close',
      () async {
        await reachConfirmedActive();
        await channel(up: false);
        final gate = repository.closeGate = Completer<void>();
        bloc.add(const RemoteSessionCloseRequested());
        bloc.add(const RemoteSessionCloseRequested());
        await settle();
        gate.complete();
        await settle();

        expect(repository.closedIds, [testRemoteSessionId]);
      },
    );

    test('15. an answer that belongs to a dropped identity is discarded, and '
        'no retry outlives the reset', () async {
      await reachConfirmedActive();
      await channel(up: false);
      final gate = repository.currentGate = Completer<void>();
      await elapse(const Duration(seconds: 2));

      bloc.add(const RemoteSessionResetRequested());
      await settle();
      gate.complete();
      await settle();

      expect(bloc.state, const RemoteSessionInitial());
      repository.currentGate = null;
      final reads = repository.currentCount;
      await elapse(RemoteSessionBloc.defaultAuthorityGracePeriod * 2);
      expect(repository.currentCount, reads);
      expect(timers.pending, isEmpty);
      expect(repository.closedIds, isEmpty);
    });

    test('16. the backend clock is never consulted: timestamps far in the '
        'past or future do not move the deadline', () async {
      repository.currentResult = Ok<RemoteSession?>(
        RemoteSession(
          id: testRemoteSessionId,
          supportRequestId: activatedSession.supportRequestId,
          status: RemoteSessionStatus.active,
          // Hours ahead of the tablet, as with the -03:00 columns seen on the
          // shared backend.
          connectedAt: DateTime.now().toUtc().add(const Duration(hours: 3)),
          technician: activatedSession.technician,
        ),
      );
      await channel(up: true);
      await sync();
      expect(confirmed(), isTrue);

      await channel(up: false);
      await elapse(
        RemoteSessionBloc.defaultAuthorityGracePeriod -
            const Duration(milliseconds: 1),
      );
      expect(bloc.state, isA<RemoteSessionActive>());
      await elapse(const Duration(milliseconds: 1));
      expect(bloc.state, isA<RemoteSessionEndedLocally>());
    });

    test('17. re-reads back off 2, 4, 8, 8... s and start over when the '
        'channel changes', () async {
      await reachConfirmedActive();
      repository.currentResult = remoteSessionUnreachable;
      final base = repository.currentCount;
      await channel(up: false);

      final readsAt = <int>[];
      for (var s = 1; s <= 30; s++) {
        final before = repository.currentCount;
        await elapse(const Duration(seconds: 1));
        if (repository.currentCount > before) readsAt.add(s);
      }
      expect(readsAt, [2, 6, 14, 22, 30]);

      await channel(up: true);
      final afterUp = repository.currentCount;
      await elapse(const Duration(seconds: 2));
      expect(repository.currentCount, afterUp + 1);
      expect(base, lessThan(afterUp));
    });

    test('after a restart, a session stopped for lost authority is still '
        'refused and still gets no close', () async {
      await reachConfirmedActive();
      repository.currentResult = remoteSessionUnreachable;
      await channel(up: false);
      await elapse(RemoteSessionBloc.defaultAuthorityGracePeriod);
      expect(endedSessionStore.closeOwed, isFalse);
      await bloc.close();

      timers = ManualTimers();
      bloc = RemoteSessionBloc(
        loadCurrentRemoteSession: LoadCurrentRemoteSession(repository),
        closeRemoteSession: CloseRemoteSession(repository),
        endedSessionStore: endedSessionStore,
        timerFactory: timers.factory,
      );
      repository.currentResult = activatedRemoteSession;
      await channel(up: true);
      await sync();

      final state = bloc.state as RemoteSessionEndedLocally;
      expect(state.reason, RemoteSessionLocalEndReason.authorityLost);
      expect(repository.closedIds, isEmpty);
    });
  });

  test(
    'M1-c: an end the user did not ask for never sends the DEVICE close',
    () async {
      await reachConfirmedActive();
      await channel(up: false);
      // Nothing reachable for well over the backend grace.
      repository.currentResult = remoteSessionUnreachable;
      await elapse(backendGrace * 3);

      expect(bloc.state, isA<RemoteSessionEndedLocally>());
      expect(repository.closedIds, isEmpty);
    },
  );
}
