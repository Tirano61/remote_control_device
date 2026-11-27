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

/// A3 of the Prompt 44 audit: a store that fails must never let a session
/// the user ended be taken back after the application restarts.
///
/// Sharing one [FakeEndedRemoteSessionStore] between two blocs is how a test
/// stands for the process dying and starting again: the second bloc starts
/// with nothing but what was stored.
///
/// The design these tests hold to (docs/remote_session/LIFECYCLE.md, "Ended
/// sessions across a restart"): a session is recorded as *held* before its
/// authority can be confirmed, so the restart guarantee does not rest on the
/// write made at FINALIZAR; a session an earlier run held is never resumed;
/// and a store that cannot be read at start refuses whatever the first answer
/// shows live.
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
    for (var i = 0; i < 16; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> sync() async {
    bloc.add(const RemoteSessionSyncRequested());
    await settle();
  }

  /// The socket comes up and the read that follows it answers [answer]: the
  /// only way a session is confirmed.
  Future<void> connectAndRead(Result<RemoteSession?> answer) async {
    repository.currentResult = answer;
    bloc.add(const RemoteSessionAuthorityChannelChanged(available: true));
    await sync();
  }

  Future<void> reachConfirmedActive() async {
    await connectAndRead(activatedRemoteSession);
    final state = bloc.state;
    expect(state, isA<RemoteSessionActive>());
    expect((state as RemoteSessionActive).isSuspended, isFalse);
  }

  Future<void> restart() async {
    await bloc.close();
    bloc = build();
  }

  bool isConfirmedLive(RemoteSessionState state) =>
      state is RemoteSessionLive && !state.isSuspended;

  const otherActive = Ok<RemoteSession?>(
    RemoteSession(
      id: testOtherRemoteSessionId,
      supportRequestId: testSupportRequestId,
      status: RemoteSessionStatus.active,
      technician: testRemoteSessionTechnician,
    ),
  );

  group('the held record', () {
    test('is written before the session can be confirmed', () async {
      await reachConfirmedActive();

      expect(store.held, testRemoteSessionId);
      expect(store.heldCalls, ['readHeld', ('writeHeld', testRemoteSessionId)]);
    });

    test(
      'a session whose record cannot be written is never confirmed',
      () async {
        store.failingWrites = true;

        await connectAndRead(activatedRemoteSession);

        final state = bloc.state;
        expect(state, isA<RemoteSessionActive>());
        expect((state as RemoteSessionActive).isSuspended, isTrue);
        // Tried twice, then left for the next read.
        expect(store.heldCalls.whereType<(String, String)>(), hasLength(2));
      },
    );

    test('a later read that can write it confirms the session', () async {
      store.failingWrites = true;
      await connectAndRead(activatedRemoteSession);
      expect(isConfirmedLive(bloc.state), isFalse);

      store.failingWrites = false;
      await sync();

      expect(isConfirmedLive(bloc.state), isTrue);
      expect(store.held, testRemoteSessionId);
    });

    test('is written once per session, not on every read', () async {
      await reachConfirmedActive();
      await sync();
      await sync();

      expect(store.heldCalls.whereType<(String, String)>(), hasLength(1));
    });

    test('is cleared once the backend confirms the close', () async {
      await reachConfirmedActive();
      repository.currentQueue.add(noRemoteSession);

      bloc.add(const RemoteSessionCloseRequested());
      await settle();

      expect(bloc.state, const RemoteSessionIdle());
      expect(store.held, isNull);
      expect(store.value, isNull);
    });

    test('is cleared once a read shows the session gone', () async {
      await reachConfirmedActive();

      repository.currentResult = noRemoteSession;
      await sync();

      expect(bloc.state, isA<RemoteSessionIdle>());
      expect(store.held, isNull);
    });
  });

  group('A3: FINALIZAR whose marker cannot be written', () {
    Future<void> finalizarUnwritten() async {
      await reachConfirmedActive();
      store.failingWrites = true;
      repository.closeResult = closeUnreachable;
      bloc.add(const RemoteSessionCloseRequested());
      await settle();
      expect(bloc.state, isA<RemoteSessionEndedLocally>());
      // Nothing about the end reached the store.
      expect(store.value, isNull);
    }

    test('the local end does not wait for the store, and stays', () async {
      await finalizarUnwritten();

      repository.currentResult = activatedRemoteSession;
      await sync();
      expect(bloc.state, isA<RemoteSessionEndedLocally>());
    });

    test('A3: restart with REST still ACTIVE: not resumed', () async {
      await finalizarUnwritten();

      await restart();
      store.failingWrites = false;
      await connectAndRead(activatedRemoteSession);

      expect(bloc.state, isNot(isA<RemoteSessionLive>()));
      expect(
        bloc.state,
        const RemoteSessionEndedLocally(
          testRemoteSessionId,
          reason: RemoteSessionLocalEndReason.notResumable,
        ),
      );
    });

    test('restart with REST ACTIVE sends no close: the user may not have '
        'asked for one, and SYSTEM closes it', () async {
      await finalizarUnwritten();
      final closesBefore = repository.closedIds.length;

      await restart();
      store.failingWrites = false;
      await connectAndRead(activatedRemoteSession);
      await sync();
      bloc.add(const RemoteSessionCloseRequested());
      await settle();

      expect(repository.closedIds, hasLength(closesBefore));
    });

    test(
      'restart with REST null: idle, and the stale record is cleared',
      () async {
        await finalizarUnwritten();

        await restart();
        store.failingWrites = false;
        await connectAndRead(noRemoteSession);

        expect(bloc.state, isA<RemoteSessionIdle>());
        expect(store.held, isNull);
      },
    );

    test(
      'restart, then the backend closes it as SYSTEM: idle, never live',
      () async {
        await finalizarUnwritten();

        await restart();
        store.failingWrites = false;
        await connectAndRead(activatedRemoteSession);
        final seen = <RemoteSessionState>[];
        final subscription = bloc.stream.listen(seen.add);
        repository.currentResult = noRemoteSession;
        await sync();
        await subscription.cancel();

        expect(bloc.state, isA<RemoteSessionIdle>());
        expect(seen.whereType<RemoteSessionLive>(), isEmpty);
      },
    );

    test(
      'a later answer about it, after the restart, never makes it live',
      () async {
        await finalizarUnwritten();

        await restart();
        store.failingWrites = false;
        await connectAndRead(activatedRemoteSession);
        bloc.add(const RemoteSessionActivationAnnounced(testRemoteSessionId));
        bloc.add(const RemoteSessionAnnounced(testRemoteSessionId));
        await settle();
        await sync();

        expect(bloc.state, isNot(isA<RemoteSessionLive>()));
      },
    );

    test(
      'a new assistance after it goes the normal way, and is confirmed',
      () async {
        await finalizarUnwritten();
        await restart();
        store.failingWrites = false;
        await connectAndRead(activatedRemoteSession);

        // The old one is closed by the backend; the user asks again.
        repository.currentResult = otherActive;
        await sync();

        final state = bloc.state;
        expect(state, isA<RemoteSessionActive>());
        expect(
          (state as RemoteSessionActive).session.id,
          testOtherRemoteSessionId,
        );
        expect(state.isSuspended, isFalse);
        expect(store.held, testOtherRemoteSessionId);
      },
    );
  });

  group('a FINALIZAR whose marker was written', () {
    test(
      'restart with REST ACTIVE closes it again as DEVICE, as before',
      () async {
        await reachConfirmedActive();
        repository.closeResult = closeUnreachable;
        bloc.add(const RemoteSessionCloseRequested());
        await settle();
        expect(store.value, testRemoteSessionId);
        final closes = repository.closedIds.length;

        await restart();
        repository.closeResult = closeUnreachable;
        await connectAndRead(activatedRemoteSession);

        expect(bloc.state, isA<RemoteSessionEndedLocally>());
        expect(
          (bloc.state as RemoteSessionEndedLocally).reason,
          RemoteSessionLocalEndReason.userRequest,
        );
        expect(repository.closedIds, hasLength(closes + 1));
      },
    );
  });

  group('an earlier run that took part and recorded nothing else', () {
    test('a crash during the assistance: the session is not resumed', () async {
      await reachConfirmedActive();

      // No FINALIZAR: the process simply dies.
      await restart();
      await connectAndRead(activatedRemoteSession);

      expect(bloc.state, isNot(isA<RemoteSessionLive>()));
      expect(
        (bloc.state as RemoteSessionEndedLocally).reason,
        RemoteSessionLocalEndReason.notResumable,
      );
      expect(repository.closedIds, isEmpty);
    });
  });

  group('a store that cannot be read at start', () {
    test('the session the first answer shows live is not resumed', () async {
      store
        ..value = null
        ..held = testRemoteSessionId
        ..failingReads = true;
      await restart();

      await connectAndRead(activatedRemoteSession);

      expect(bloc.state, isNot(isA<RemoteSessionLive>()));
      expect(
        (bloc.state as RemoteSessionEndedLocally).reason,
        RemoteSessionLocalEndReason.notResumable,
      );
    });

    test('each record is tried twice before giving up', () async {
      store.failingReads = true;
      await restart();

      await connectAndRead(noRemoteSession);

      expect(store.calls.where((call) => call == 'read'), hasLength(2));
      expect(store.heldCalls.where((call) => call == 'readHeld'), hasLength(2));
    });

    test(
      'with REST null first, a later new session is adopted normally',
      () async {
        store.failingReads = true;
        await restart();
        await connectAndRead(noRemoteSession);
        expect(bloc.state, isA<RemoteSessionIdle>());

        store.failingReads = false;
        repository.currentResult = otherActive;
        await sync();

        expect(isConfirmedLive(bloc.state), isTrue);
      },
    );

    test('a store that fails entirely gives no control at all', () async {
      store.failing = true;
      await restart();

      await connectAndRead(activatedRemoteSession);
      expect(isConfirmedLive(bloc.state), isFalse);

      repository.currentResult = otherActive;
      await sync();
      expect(isConfirmedLive(bloc.state), isFalse);
    });

    test('a failed read is not a reason to send a close', () async {
      store.failingReads = true;
      await restart();

      await connectAndRead(activatedRemoteSession);
      bloc.add(const RemoteSessionCloseRequested());
      await settle();

      expect(repository.closedIds, isEmpty);
    });
  });

  group('the network failing on the read after a restart', () {
    test(
      'a failed first read refuses nothing yet, and grants nothing',
      () async {
        await reachConfirmedActive();
        await restart();

        repository.currentResult = const Err<RemoteSession?>(NetworkFailure());
        bloc.add(const RemoteSessionAuthorityChannelChanged(available: true));
        await sync();
        expect(bloc.state, isA<RemoteSessionUnavailable>());

        repository.currentResult = activatedRemoteSession;
        await sync();
        expect(bloc.state, isNot(isA<RemoteSessionLive>()));
      },
    );
  });
}
