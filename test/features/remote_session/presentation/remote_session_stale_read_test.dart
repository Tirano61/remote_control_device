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

/// Prompt 41 (D1 of the BACKEND Prompt 35 audit): a `/current` answer that is
/// older than one already taken into account.
///
/// Two reads can be on the wire at once — a re-read of a suspended session and
/// the read the socket's return causes, a cue and a retry — and nothing makes
/// them answer in the order they left. Every read here is held by the fake
/// until the test answers it, so the order is the test's, not a clock's.
void main() {
  late FakeRemoteSessionRepository repository;
  late FakeEndedRemoteSessionStore endedSessionStore;
  late ManualTimers timers;
  late RemoteSessionBloc bloc;
  late List<RemoteSessionState> seen;
  late StreamSubscription<RemoteSessionState> subscription;

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
    seen = [];
    subscription = bloc.stream.listen(seen.add);
  });

  tearDown(() async {
    await subscription.cancel();
    await bloc.close();
  });

  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
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

  /// Answers the [index]-th read still held (0 = the oldest one made).
  Future<void> answer(int index, Result<RemoteSession?> result) async {
    repository.heldReads[index].complete(result);
    await settle();
  }

  bool confirmed() {
    final state = bloc.state;
    return state is RemoteSessionLive &&
        state.authority == RemoteSessionAuthority.confirmed;
  }

  bool suspended() {
    final state = bloc.state;
    return state is RemoteSessionLive && state.isSuspended;
  }

  /// Whether a confirmed live state was followed, at any point, by a
  /// suspended one of the same session — the regression D1 produced.
  bool confirmationWasUndone() {
    var wasConfirmed = false;
    for (final state in seen) {
      if (state is! RemoteSessionLive) {
        wasConfirmed = false;
        continue;
      }
      if (state.authority == RemoteSessionAuthority.confirmed) {
        wasConfirmed = true;
      } else if (wasConfirmed) {
        return true;
      }
    }
    return false;
  }

  /// ACTIVE and confirmed, with every later read held for the test to answer.
  Future<void> reachConfirmedActive() async {
    await channel(up: true);
    repository.currentResult = activatedRemoteSession;
    await sync();
    expect(confirmed(), isTrue);
    repository.holdReads = true;
  }

  /// The S2 situation up to the socket's return: the socket dropped, the
  /// session was suspended, a re-read left while the network was still out
  /// and is still on the wire. Read 0 is that re-read.
  Future<void> suspendWithReadOnTheWire() async {
    await reachConfirmedActive();
    await channel(up: false);
    expect(suspended(), isTrue);
    await elapse(const Duration(seconds: 2));
    expect(repository.heldReads, hasLength(1));
  }

  /// The socket is back and the read it causes is on the wire: read 1.
  Future<void> socketBack() async {
    // Only what happens from here on is about D1: the suspension that came
    // with the drop was the right one.
    seen.clear();
    await channel(up: true);
    await sync();
    expect(repository.heldReads, hasLength(2));
  }

  group('D1, as seen in S2', () {
    test('S2: the read that left before the reconnection answers after the '
        'one that confirmed the session, and undoes nothing', () async {
      await suspendWithReadOnTheWire();
      await socketBack();

      // The new read answers first: confirmed again.
      await answer(1, activatedRemoteSession);
      expect(confirmed(), isTrue);

      // The old one answers last, with the same session ACTIVE. Before the
      // fix this put the session back to suspended, which left the signaling
      // room and lost the web's recovery offer.
      await answer(0, activatedRemoteSession);
      expect(confirmed(), isTrue);
      expect(confirmationWasUndone(), isFalse);
      expect(repository.closedIds, isEmpty);
    });

    test('the same with a failed answer from the old read', () async {
      await suspendWithReadOnTheWire();
      await socketBack();
      await answer(1, activatedRemoteSession);
      await answer(0, remoteSessionUnreachable);
      expect(confirmed(), isTrue);
      expect(confirmationWasUndone(), isFalse);
    });
  });

  const serviceUnavailable = Err<RemoteSession?>(ServerFailure());
  const timedOut = Err<RemoteSession?>(NetworkFailure());
  final closedAtCurrent = Ok<RemoteSession?>(
    closedSessionBy(RemoteSessionEndedBy.system),
  );
  final otherSession = Ok<RemoteSession?>(
    connectingSession.copyWithId(testOtherRemoteSessionId),
  );

  group('order of answers', () {
    test('1. two reads answering in the order they left: confirmed by the '
        'newer one', () async {
      await suspendWithReadOnTheWire();
      await socketBack();

      await answer(0, activatedRemoteSession);
      expect(suspended(), isTrue, reason: 'it left before the socket was back');
      await answer(1, activatedRemoteSession);
      expect(confirmed(), isTrue);
    });

    test('2-3. two reads answering in reverse order: the newer confirmation '
        'stands (S2)', () async {
      await suspendWithReadOnTheWire();
      await socketBack();
      await answer(1, activatedRemoteSession);
      await answer(0, activatedRemoteSession);
      expect(confirmed(), isTrue);
      expect(confirmationWasUndone(), isFalse);
    });

    test('4. a new suspension followed by an old confirmation: the old read '
        'confirms nothing', () async {
      await reachConfirmedActive();
      // A read leaves with the socket up...
      await sync();
      // ...the socket drops before it answers...
      await channel(up: false);
      expect(suspended(), isTrue);
      // ...and its ACTIVE answer arrives while it is still down.
      await answer(0, activatedRemoteSession);
      expect(suspended(), isTrue);

      // Back up: still nothing until a read that left after that answers.
      await channel(up: true);
      expect(suspended(), isTrue);
      await sync();
      await answer(repository.heldReads.length - 1, activatedRemoteSession);
      expect(confirmed(), isTrue);
    });

    test('5. old socket against new socket: a read made under the first '
        'socket cannot undo, nor make, the second one\'s confirmation', () async {
      await reachConfirmedActive();
      // Read 0 under socket A.
      await sync();
      // A drops, B comes up, and B's read (1) confirms.
      await channel(up: false);
      await channel(up: true);
      await sync();
      seen.clear();
      await answer(1, activatedRemoteSession);
      expect(confirmed(), isTrue);
      // Socket A's read answers last.
      await answer(0, activatedRemoteSession);
      expect(confirmed(), isTrue);
      expect(confirmationWasUndone(), isFalse);

      // And with B gone too, A's reads stay powerless: B drops, a read
      // under it answers late while C is up but has confirmed nothing yet.
      await sync(); // read 2, under B
      await channel(up: false);
      await channel(up: true);
      await answer(2, activatedRemoteSession);
      expect(suspended(), isTrue);
    });

    test('6. same epoch, two reads, reverse order: an older CONNECTING does '
        'not take ACTIVE back', () async {
      await channel(up: true);
      repository.holdReads = true;
      await sync(); // read 0, while the session is CONNECTING
      await sync(); // read 1, after the technician activated it
      await answer(1, activatedRemoteSession);
      expect(confirmed(), isTrue);
      expect(bloc.state, isA<RemoteSessionActive>());

      await answer(0, connectingRemoteSession);
      expect(bloc.state, isA<RemoteSessionActive>());
      expect(confirmed(), isTrue);
    });

    test('6b. same epoch, the older read is the one that knows more: it '
        'grants nothing itself, and a fresh read does', () async {
      await channel(up: true);
      repository.holdReads = true;
      await sync(); // read 0
      await sync(); // read 1
      await answer(1, connectingRemoteSession);
      expect(bloc.state, isA<RemoteSessionConnecting>());

      // Served later than read 1, it already saw ACTIVE.
      await answer(0, activatedRemoteSession);
      expect(bloc.state, isA<RemoteSessionConnecting>());
      // A fresh read was made instead.
      expect(repository.heldReads, hasLength(3));
      await answer(2, activatedRemoteSession);
      expect(bloc.state, isA<RemoteSessionActive>());
      expect(confirmed(), isTrue);
    });

    test('21. consecutive micro-cuts with a read left behind by each: only '
        'the last socket\'s read confirms, and nothing undoes it', () async {
      await reachConfirmedActive();
      for (var cut = 0; cut < 3; cut++) {
        await channel(up: false);
        await elapse(const Duration(seconds: 2)); // a re-read leaves
        await channel(up: true);
        await sync(); // the reconnection's read leaves
      }
      // The first suspension's re-read and one read per socket. No re-read is
      // stacked on a read already on the wire, so the later cuts add none.
      final reads = repository.heldReads.length;
      expect(reads, 4);
      seen.clear();

      // Everything but the last one answers, newest first.
      for (var i = reads - 2; i >= 0; i--) {
        await answer(i, activatedRemoteSession);
        expect(confirmed(), isFalse, reason: 'read $i is from an old socket');
      }
      await answer(reads - 1, activatedRemoteSession);
      expect(confirmed(), isTrue);
      expect(confirmationWasUndone(), isFalse);
      expect(repository.closedIds, isEmpty);
    });

    test('22. a retry scheduled under an old suspension answering late after '
        'the recovery changes nothing, and stacks no further retry', () async {
      await suspendWithReadOnTheWire();
      await socketBack();
      await answer(1, activatedRemoteSession);
      await answer(0, timedOut);
      final reads = repository.currentCount;
      await elapse(const Duration(seconds: 60));
      expect(confirmed(), isTrue);
      expect(repository.currentCount, reads);
      expect(timers.pending, isEmpty);
    });
  });

  group('revocations are never ignored', () {
    test('9. an overtaken read that answers no session, made after the '
        'session was known, still ends it', () async {
      await suspendWithReadOnTheWire();
      await socketBack();
      // Read 1 confirms; read 0 — which left during the suspension, with the
      // session already known — comes back without it: served after the
      // backend closed it, whatever order the two arrived in.
      await answer(1, activatedRemoteSession);
      expect(confirmed(), isTrue);
      await answer(0, noRemoteSession);

      expect(bloc.state, isA<RemoteSessionIdle>());
      expect(repository.closedIds, isEmpty);
    });

    test('9b. and once over, no later answer — however ordered — makes it '
        'live again', () async {
      await reachConfirmedActive();
      await sync(); // read 0
      await sync(); // read 1
      await answer(1, noRemoteSession);
      expect(bloc.state, isA<RemoteSessionIdle>());

      await answer(0, activatedRemoteSession);
      expect(bloc.state, isA<RemoteSessionIdle>());

      // Even the newest read answering it ACTIVE is a read served before the
      // close: a CLOSED session is never live again.
      await sync();
      await answer(2, activatedRemoteSession);
      expect(bloc.state, isNot(isA<RemoteSessionLive>()));
    });

    test('10. /current answering the session CLOSED ends it like no session',
        () async {
      await reachConfirmedActive();
      await sync();
      await answer(0, closedAtCurrent);
      expect(bloc.state, isA<RemoteSessionIdle>());
    });

    test('contradiction that proves nothing: a read that may have been served '
        'before the session existed suspends it and asks again', () async {
      await channel(up: true);
      repository.holdReads = true;
      await sync(); // read 0: left before the session existed
      await sync(); // read 1
      await answer(1, connectingRemoteSession);
      expect(confirmed(), isTrue);

      seen.clear();
      await answer(0, noRemoteSession);
      // Neither ended nor still vouched for.
      expect(bloc.state, isA<RemoteSessionConnecting>());
      expect(suspended(), isTrue);
      expect(repository.heldReads, hasLength(3));

      // The fresh read settles it, both ways.
      await answer(2, connectingRemoteSession);
      expect(confirmed(), isTrue);
    });

    test('the same contradiction, settled the other way: the fresh read finds '
        'it gone', () async {
      await channel(up: true);
      repository.holdReads = true;
      await sync();
      await sync();
      await answer(1, connectingRemoteSession);
      await answer(0, noRemoteSession);
      await answer(2, noRemoteSession);
      expect(bloc.state, isA<RemoteSessionIdle>());
    });

    test('8. REST ACTIVE after remote-session:closed: never live again',
        () async {
      await suspendWithReadOnTheWire();
      await socketBack();
      bloc.add(
        const RemoteSessionClosureAnnounced(
          testRemoteSessionId,
          endedBy: RemoteSessionEndedBy.system,
        ),
      );
      await settle();
      expect(bloc.state, isA<RemoteSessionClosedRemotely>());

      await answer(1, activatedRemoteSession);
      await answer(0, activatedRemoteSession);
      for (var i = 2; i < repository.heldReads.length; i++) {
        await answer(i, activatedRemoteSession);
      }
      expect(bloc.state, isNot(isA<RemoteSessionLive>()));
      expect(
        seen.whereType<RemoteSessionLive>().where(
          (s) => s.authority == RemoteSessionAuthority.confirmed,
        ),
        isEmpty,
      );
      expect(repository.closedIds, isEmpty);
    });

    test('7/24. REST ACTIVE after FINALIZAR: ended at once, one close, never '
        'live again whatever order the reads answer in', () async {
      await suspendWithReadOnTheWire();
      await socketBack();
      repository.closeResult = closeUnreachable;
      bloc.add(const RemoteSessionCloseRequested());
      await settle();
      expect(bloc.state, isA<RemoteSessionEndedLocally>());
      expect(repository.closedIds, [testRemoteSessionId]);

      await answer(1, activatedRemoteSession);
      await answer(0, activatedRemoteSession);
      expect(bloc.state, isA<RemoteSessionEndedLocally>());
      expect(endedSessionStore.value, testRemoteSessionId);
      expect(endedSessionStore.closeOwed, isTrue);

      // The backend records the close on the next attempt.
      repository.closeResult = Ok(closedSession);
      repository.holdReads = false;
      repository.currentResult = noRemoteSession;
      bloc.add(const RemoteSessionCloseRequested());
      await settle();
      expect(bloc.state, isA<RemoteSessionIdle>());
      expect(endedSessionStore.value, isNull);
      expect(
        seen.skipWhile((s) => s is! RemoteSessionEndedLocally),
        everyElement(isNot(isA<RemoteSessionLive>())),
      );
    });

    test('FINALIZAR confirmed: a read still on the wire answering ACTIVE does '
        'not flip the state back, and no second close is sent', () async {
      await suspendWithReadOnTheWire();
      await socketBack();
      await answer(1, activatedRemoteSession);
      bloc.add(const RemoteSessionCloseRequested());
      await settle();
      // The close is confirmed; the read that follows it is held.
      expect(repository.closedIds, [testRemoteSessionId]);
      await answer(2, noRemoteSession);
      expect(bloc.state, isA<RemoteSessionIdle>());

      await answer(0, activatedRemoteSession);
      expect(bloc.state, isA<RemoteSessionIdle>());
      expect(repository.closedIds, [testRemoteSessionId]);
    });

    test('a stale "no session" never confirms a FINALIZAR the backend may '
        'not have recorded: the marker stays until a read proves it', () async {
      await channel(up: true);
      repository.holdReads = true;
      await sync(); // read 0: before the session existed
      await sync(); // read 1
      await answer(1, activatedRemoteSession);
      repository.closeResult = closeUnreachable;
      bloc.add(const RemoteSessionCloseRequested());
      await settle();
      expect(endedSessionStore.value, testRemoteSessionId);

      await answer(0, noRemoteSession);
      expect(endedSessionStore.value, testRemoteSessionId);
      expect(bloc.state, isA<RemoteSessionEndedLocally>());

      // The fresh read it caused left after the session was known.
      repository.closeResult = Ok(closedSession);
      await answer(repository.heldReads.length - 1, noRemoteSession);
      expect(endedSessionStore.value, isNull);
      expect(bloc.state, isA<RemoteSessionIdle>());
    });
  });

  group('failures', () {
    test('11. 503 while suspended: still suspended, nothing confirmed, the '
        'next re-read is scheduled', () async {
      await suspendWithReadOnTheWire();
      await socketBack();
      await answer(1, serviceUnavailable);
      expect(suspended(), isTrue);
      await answer(0, serviceUnavailable);
      expect(suspended(), isTrue);

      await elapse(const Duration(seconds: 2));
      expect(repository.heldReads, hasLength(3));
      await answer(2, activatedRemoteSession);
      expect(confirmed(), isTrue);
    });

    test('11b. 503 from the newest read after a confirmation: kept', () async {
      await reachConfirmedActive();
      await sync();
      await answer(0, serviceUnavailable);
      expect(confirmed(), isTrue);
    });

    test('12. timeout of the reconnection\'s read, then a stale ACTIVE: '
        'still suspended until a fresh read answers', () async {
      await suspendWithReadOnTheWire();
      await socketBack();
      await answer(1, timedOut);
      await answer(0, activatedRemoteSession);
      expect(suspended(), isTrue);

      await elapse(const Duration(seconds: 2));
      await answer(2, activatedRemoteSession);
      expect(confirmed(), isTrue);
    });
  });

  group('what comes after', () {
    test('23. a new session after the old one is over: adopted normally, and '
        'a late answer about the old one disturbs nothing', () async {
      await reachConfirmedActive();
      await sync(); // read 0, about the first session
      await sync(); // read 1
      await answer(1, noRemoteSession);
      expect(bloc.state, isA<RemoteSessionIdle>());

      await sync(); // read 2: a new assistance
      await answer(2, otherSession);
      expect(bloc.state, isA<RemoteSessionConnecting>());
      expect(
        (bloc.state as RemoteSessionLive).session.id,
        testOtherRemoteSessionId,
      );
      expect(confirmed(), isTrue);

      await answer(0, activatedRemoteSession);
      expect(
        (bloc.state as RemoteSessionLive).session.id,
        testOtherRemoteSessionId,
      );
      expect(confirmed(), isTrue);
    });

    test('the grace period still runs out when only stale answers arrive',
        () async {
      await suspendWithReadOnTheWire();
      // The socket never comes back; the read answers ACTIVE.
      await answer(0, activatedRemoteSession);
      expect(suspended(), isTrue);
      repository.holdReads = false;
      repository.currentResult = activatedRemoteSession;
      await elapse(RemoteSessionBloc.defaultAuthorityGracePeriod);
      expect(bloc.state, isA<RemoteSessionEndedLocally>());
      expect(repository.closedIds, isEmpty);
      expect(endedSessionStore.closeOwed, isFalse);
    });
  });
}

extension on RemoteSession {
  RemoteSession copyWithId(String id) => RemoteSession(
    id: id,
    supportRequestId: supportRequestId,
    status: status,
    connectedAt: connectedAt,
    endedAt: endedAt,
    endedBy: endedBy,
    technician: technician,
  );
}
