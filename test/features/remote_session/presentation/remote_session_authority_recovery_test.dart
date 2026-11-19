import 'package:flutter_test/flutter_test.dart';
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
