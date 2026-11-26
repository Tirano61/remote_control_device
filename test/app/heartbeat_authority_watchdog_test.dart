import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/app/device_realtime_coordinator.dart';
import 'package:remote_control_device/app/remote_session_coordinator.dart';
import 'package:remote_control_device/app/signaling_coordinator.dart';
import 'package:remote_control_device/app/support_coordinator.dart';
import 'package:remote_control_device/app/webrtc_coordinator.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/core/session/device_credential_revocation.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_signal.dart';
import 'package:remote_control_device/features/device/domain/realtime/heartbeat_watchdog.dart';
import 'package:remote_control_device/features/device/domain/realtime/realtime_heartbeat_policy.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/check_device_status.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/device/domain/usecases/suspend_device_authorization.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_device/features/signaling/presentation/bloc/signaling/signaling_bloc.dart';
import 'package:remote_control_device/features/support/domain/usecases/accept_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/cancel_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/load_current_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/reject_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/request_support.dart';
import 'package:remote_control_device/features/support/presentation/bloc/support/support_bloc.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_message.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_state.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_device/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../fakes/device_fakes.dart';
import '../fakes/manual_timers.dart';
import '../fakes/realtime_fakes.dart';
import '../fakes/remote_control_fakes.dart';
import '../fakes/remote_session_fakes.dart';
import '../fakes/screen_capture_fakes.dart';
import '../fakes/signaling_fakes.dart';
import '../fakes/support_fakes.dart';
import '../fakes/webrtc_fakes.dart';

/// The backend's heartbeat, as its handshake announces it.
const RealtimeHeartbeatPolicy policy1010 = RealtimeHeartbeatPolicy(
  pingInterval: Duration(seconds: 10),
  pingTimeout: Duration(seconds: 10),
);

Duration ms(int value) => Duration(milliseconds: value);
Duration s(num value) => Duration(milliseconds: (value * 1000).round());

/// Prompt 42, end to end: the heartbeat watchdog against every bloc and
/// coordinator, the real ones. The socket, REST, the peer, the capture and
/// the accessibility service are faked; every deadline — the watchdog's, the
/// authority grace and its re-reads, the orphan capture window — runs on one
/// [ManualTimers], so 13 s are tested in microseconds and at their edges.
///
/// A half-open connection, as the backend's relay measured it: the transport
/// keeps calling the socket connected and simply receives nothing, until its
/// own `ping timeout` 20 s after the last `PING`. Here that is: PINGs stop,
/// and [RealtimeDisconnected] is emitted when the test says the transport
/// gave up.
void main() {
  late FakeDeviceRealtimeClient client;
  late FakeRemoteSessionRepository remoteSessionRepository;
  late FakeEndedRemoteSessionStore endedSessionStore;
  late FakeWebRtcPeerConnectionFactory peerFactory;
  late FakeScreenCaptureClient screenCapture;
  late FakeRemoteControlAccessibilityClient accessibility;
  late DeviceCredentialRevocation credentialRevocation;
  late ManualTimers timers;
  late HeartbeatWatchdog watchdog;

  /// The tablet's clocks running ahead of its timers: an isolate that was
  /// blocked, or a device that slept (the wall clock part).
  late Duration clocksAhead;

  late DeviceSessionBloc sessionBloc;
  late DeviceRealtimeBloc realtimeBloc;
  late SupportBloc supportBloc;
  late RemoteSessionBloc remoteSessionBloc;
  late SignalingBloc signalingBloc;
  late WebRtcSessionBloc webRtcBloc;

  late List<Future<void> Function()> disposers;

  setUp(() {
    client = FakeDeviceRealtimeClient();
    final storage = FakeDeviceCredentialsStorage(testCredentials);
    final tokenStore = InMemoryDeviceTokenStore();
    final authRepository = FakeDeviceAuthRepository(tokenStore: tokenStore);
    final supportRepository = FakeSupportRepository();
    remoteSessionRepository = FakeRemoteSessionRepository();
    endedSessionStore = FakeEndedRemoteSessionStore();
    peerFactory = FakeWebRtcPeerConnectionFactory();
    screenCapture = FakeScreenCaptureClient();
    accessibility = FakeRemoteControlAccessibilityClient();
    credentialRevocation = DeviceCredentialRevocation();
    timers = ManualTimers();
    clocksAhead = Duration.zero;
    watchdog = HeartbeatWatchdog(
      timerFactory: timers.factory,
      monotonicClock: () => timers.now + clocksAhead,
      wallClock: () => DateTime.utc(2026, 11, 26).add(timers.now + clocksAhead),
    );

    final loadDeviceCredentials = LoadDeviceCredentials(storage);
    final authenticateDevice = AuthenticateDevice(authRepository);

    sessionBloc = DeviceSessionBloc(
      loadDeviceCredentials: loadDeviceCredentials,
      authenticateDevice: authenticateDevice,
      checkDeviceStatus: CheckDeviceStatus(authRepository),
      suspendDeviceAuthorization: SuspendDeviceAuthorization(authRepository),
    );
    realtimeBloc = DeviceRealtimeBloc(
      client: client,
      tokenStore: tokenStore,
      renewDeviceToken: RenewDeviceToken(
        loadDeviceCredentials: loadDeviceCredentials,
        authenticateDevice: authenticateDevice,
      ),
      reauthRetryDelay: const Duration(milliseconds: 20),
      heartbeatWatchdog: watchdog,
    );
    supportBloc = SupportBloc(
      requestSupport: RequestSupport(supportRepository),
      loadCurrentSupportRequest: LoadCurrentSupportRequest(supportRepository),
      acceptSupportRequest: AcceptSupportRequest(supportRepository),
      rejectSupportRequest: RejectSupportRequest(supportRepository),
      cancelSupportRequest: CancelSupportRequest(supportRepository),
    );
    remoteSessionBloc = RemoteSessionBloc(
      loadCurrentRemoteSession: LoadCurrentRemoteSession(
        remoteSessionRepository,
      ),
      closeRemoteSession: CloseRemoteSession(remoteSessionRepository),
      endedSessionStore: endedSessionStore,
      timerFactory: timers.factory,
    );
    signalingBloc = SignalingBloc(client: client);
    webRtcBloc = WebRtcSessionBloc(
      peerConnectionFactory: peerFactory,
      signaling: signalingBloc,
      iceConfiguration: const WebRtcIceConfiguration.none(),
      screenCapture: screenCapture,
      remoteControl: accessibility,
      timerFactory: timers.factory,
      channelLiveness: watchdog,
    );

    final realtimeCoordinator = DeviceRealtimeCoordinator(
      sessionBloc: sessionBloc,
      realtimeBloc: realtimeBloc,
      credentialRevocation: credentialRevocation,
    )..start();
    final supportCoordinator = SupportCoordinator(
      realtimeClient: client,
      realtimeBloc: realtimeBloc,
      sessionBloc: sessionBloc,
      supportBloc: supportBloc,
    )..start();
    final remoteSessionCoordinator = RemoteSessionCoordinator(
      realtimeClient: client,
      realtimeBloc: realtimeBloc,
      sessionBloc: sessionBloc,
      supportBloc: supportBloc,
      remoteSessionBloc: remoteSessionBloc,
    )..start();
    final signalingCoordinator = SignalingCoordinator(
      realtimeBloc: realtimeBloc,
      remoteSessionBloc: remoteSessionBloc,
      signalingBloc: signalingBloc,
    )..start();
    final webRtcCoordinator = WebRtcCoordinator(
      signalingBloc: signalingBloc,
      remoteSessionBloc: remoteSessionBloc,
      webRtcBloc: webRtcBloc,
    )..start();

    disposers = [
      webRtcCoordinator.dispose,
      signalingCoordinator.dispose,
      remoteSessionCoordinator.dispose,
      supportCoordinator.dispose,
      realtimeCoordinator.dispose,
      credentialRevocation.dispose,
      webRtcBloc.close,
      signalingBloc.close,
      remoteSessionBloc.close,
      supportBloc.close,
      realtimeBloc.close,
      sessionBloc.close,
    ];
  });

  tearDown(() async {
    for (final dispose in disposers) {
      await dispose();
    }
  });

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> elapse(Duration duration) async {
    timers.elapse(duration);
    await settle();
  }

  /// One Engine.IO PING reaching the tablet now.
  Future<void> ping() async {
    await client.emit(const RealtimeHeartbeat());
    await settle();
  }

  /// [count] PINGs, [every] apart.
  Future<void> pings(int count, {Duration every = const Duration(seconds: 10)}) async {
    for (var i = 0; i < count; i++) {
      await elapse(every);
      await ping();
    }
  }

  Future<void> connectSocket() async {
    await client.emit(const RealtimeConnected(heartbeat: policy1010));
    await settle();
  }

  Future<bool> tapRuns(FakeWebRtcDataChannel channel, String id) async {
    final before = accessibility.taps.length;
    channel.pushTap(id);
    await settle();
    return accessibility.taps.length > before;
  }

  bool refusedAsNotActive(FakeWebRtcDataChannel channel, String id) =>
      channel.sentAcks.any(
        (ack) =>
            ack.id == id &&
            !ack.ok &&
            ack.error == RemoteControlError.sessionNotActive,
      );

  bool authorityConfirmed() {
    final state = remoteSessionBloc.state;
    return state is RemoteSessionLive &&
        state.authority == RemoteSessionAuthority.confirmed;
  }

  bool suspended() {
    final state = remoteSessionBloc.state;
    return state is RemoteSessionLive && state.isSuspended;
  }

  bool joined() => signalingBloc.state is SignalingJoined;

  /// Socket up with the backend's 10/10, room joined, peer connected, control
  /// channel open, screen shared and transmitted, session ACTIVE. No time has
  /// passed: the watchdog's first deadline is 13 s ahead.
  Future<(FakeWebRtcPeerConnection, FakeWebRtcDataChannel)>
  reachActiveAssistance() async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    sessionBloc.add(const DeviceSessionStarted());
    await settle();
    realtimeBloc.add(const DeviceRealtimeStartRequested());
    await settle();
    await connectSocket();

    await client.deliver(offerReceived());
    await settle();
    final peer = peerFactory.last;
    peer.pushConnectionState(WebRtcConnectionState.connected);
    final channel = peer.pushDataChannel();
    await settle();
    channel.pushState(WebRtcDataChannelState.open);
    await settle();

    remoteSessionRepository.currentResult = activatedRemoteSession;
    await client.emit(
      const RealtimeRemoteSessionActivated(testRemoteSessionId),
    );
    await settle();

    expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
    expect(authorityConfirmed(), isTrue);
    expect(joined(), isTrue);
    expect(screenCapture.transmitting, isTrue);
    expect(await tapRuns(channel, 'before'), isTrue);
    return (peer, channel);
  }

  /// Everything the suspension must have done, and everything it must have
  /// kept.
  void expectSuspendedAndKept(FakeWebRtcPeerConnection peer) {
    expect(suspended(), isTrue);
    expect(joined(), isFalse, reason: 'room left until confirmed');
    expect(screenCapture.transmitting, isFalse, reason: 'video held back');
    expect(screenCapture.isActive, isTrue, reason: 'MediaProjection kept');
    expect(screenCapture.stopCount, 0);
    expect(peer.isClosed, isFalse, reason: 'peer kept for the recovery');
    expect(remoteSessionRepository.closedIds, isEmpty);
  }

  void pushHold(FakeWebRtcDataChannel channel) => channel.pushFrame(
    const WebRtcDataChannelMessage.text(
      '{"v":1,"type":"touch_hold","id":"hold-1","touch":"t-1",'
      '"x":0.41,"y":0.52}',
    ),
  );

  group('the deadline', () {
    test('1-2. a normal assistance through many heartbeats: never suspended, '
        'no extra read, video and control throughout', () async {
      final (_, channel) = await reachActiveAssistance();
      final reads = remoteSessionRepository.currentCount;
      final joins = client.joinedSessionIds.length;
      final switches = screenCapture.transmissions.length;
      // 10 s plus a round trip that varies up to 2.5 s.
      for (var i = 0; i < 30; i++) {
        await elapse(ms(10000 + (i % 6) * 500));
        await ping();
      }
      expect(authorityConfirmed(), isTrue);
      expect(joined(), isTrue);
      expect(screenCapture.transmitting, isTrue);
      expect(
        screenCapture.transmissions,
        hasLength(switches),
        reason: 'the gate never closed',
      );
      expect(remoteSessionRepository.currentCount, reads);
      expect(client.joinedSessionIds, hasLength(joins));
      expect(await tapRuns(channel, 'after 30 PINGs'), isTrue);
    });

    test('3. the first PING arriving 12.9 s after the connection is in time',
        () async {
      await reachActiveAssistance();
      await elapse(ms(12900));
      await ping();
      await elapse(ms(12999));
      expect(authorityConfirmed(), isTrue);
    });

    test('4-5, 16-17, 19. no PING for 13 s: authority suspended, video held, '
        'commands refused, MediaProjection and peer kept', () async {
      final (peer, channel) = await reachActiveAssistance();
      await pings(1);
      await elapse(ms(12999));
      expect(authorityConfirmed(), isTrue);
      expect(await tapRuns(channel, 'at 12.999 s'), isTrue);

      await elapse(ms(1));
      expect(realtimeBloc.state, isA<DeviceRealtimeHeartbeatOverdue>());
      expectSuspendedAndKept(peer);
      expect(await tapRuns(channel, 'at 13 s'), isFalse);
      expect(refusedAsNotActive(channel, 'at 13 s'), isTrue);
      expect(client.disconnectCount, 0, reason: 'the socket is left alone');
    });

    test('18. a DRAG held when the heartbeat goes overdue is abandoned, never '
        'released', () async {
      final (_, channel) = await reachActiveAssistance();
      pushHold(channel);
      await settle();
      accessibility.answerStart();
      await settle();
      final handle =
          (accessibility.touchCalls.last as (String, int, double, double)).$2;

      await elapse(s(13));
      expect(accessibility.touchCalls, contains(('abandon', handle)));
      expect(
        accessibility.touchCalls
            .whereType<(String, int, int, double, double)>(),
        isEmpty,
        reason: 'no release',
      );
      // The technician keeps dragging: nothing reaches Android.
      final calls = accessibility.touchCalls.length;
      pushHold(channel);
      await settle();
      expect(accessibility.touchCalls, hasLength(calls));
    });
  });

  group('reconciliation on the same socket', () {
    test('11, 30. a PING after the overdue does not confirm by itself; the '
        'REST read made after it does, and only then is the room joined and '
        'the same capture let through', () async {
      final (peer, channel) = await reachActiveAssistance();
      await elapse(s(13));
      expectSuspendedAndKept(peer);

      remoteSessionRepository.holdReads = true;
      await ping(); // 13 s late, same socket
      expect(realtimeBloc.state, isA<DeviceRealtimeConnected>());
      expect(suspended(), isTrue, reason: 'a PING grants nothing');
      expect(joined(), isFalse);
      expect(screenCapture.transmitting, isFalse);
      expect(await tapRuns(channel, 'after the PING'), isFalse);

      // The read the PING's "channel up" caused.
      final read = remoteSessionRepository.heldReads.last;
      read.complete(activatedRemoteSession);
      await settle();
      expect(authorityConfirmed(), isTrue);
      expect(joined(), isTrue);
      expect(screenCapture.transmitting, isTrue);
      expect(screenCapture.dialogs, [testRemoteSessionId], reason: 'no dialog');
      expect(peer.isClosed, isFalse);
      expect(await tapRuns(channel, 'after the read'), isTrue);
    });

    test('10. while the read after the PING is pending: suspended, no join, '
        'no video', () async {
      final (peer, channel) = await reachActiveAssistance();
      await elapse(s(13));
      remoteSessionRepository.holdReads = true;
      await ping();
      await elapse(s(5));
      expectSuspendedAndKept(peer);
      expect(await tapRuns(channel, 'pending'), isFalse);
    });

    test('12. an ACTIVE read that left before the overdue cannot confirm, even '
        'answered after the PING', () async {
      final (peer, _) = await reachActiveAssistance();
      remoteSessionRepository.holdReads = true;
      remoteSessionBloc.add(const RemoteSessionSyncRequested());
      await settle();
      expect(remoteSessionRepository.heldReads, hasLength(1));

      await elapse(s(13));
      await ping();
      // The old read answers: older than the suspension and than the PING.
      remoteSessionRepository.heldReads.first.complete(activatedRemoteSession);
      await settle();
      expect(authorityConfirmed(), isFalse);
      expectSuspendedAndKept(peer);
    });

    test('a read answered ACTIVE while still overdue confirms nothing', () async {
      final (peer, _) = await reachActiveAssistance();
      await elapse(s(13));
      // The suspension's own re-reads, at +2, +4, +8 s: all ACTIVE.
      await elapse(s(14) - ms(1));
      expect(remoteSessionRepository.currentCount, greaterThanOrEqualTo(3));
      expectSuspendedAndKept(peer);
    });

    test('13. the read after the PING answers no session: torn down',
        () async {
      final (peer, _) = await reachActiveAssistance();
      await elapse(s(13));
      remoteSessionRepository.currentResult = noRemoteSession;
      await ping();
      expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
      expect(peer.isClosed, isTrue);
      expect(screenCapture.isActive, isFalse);
      expect(remoteSessionRepository.closedIds, isEmpty);
    });

    test('14. the read after the PING fails with 503: suspended, re-read on '
        'the backoff, confirmed once it answers', () async {
      final (peer, channel) = await reachActiveAssistance();
      await elapse(s(13));
      remoteSessionRepository.currentResult = remoteSessionUnreachable;
      await ping();
      await pings(2);
      expectSuspendedAndKept(peer);
      final reads = remoteSessionRepository.currentCount;

      remoteSessionRepository.currentResult = activatedRemoteSession;
      await pings(1);
      expect(remoteSessionRepository.currentCount, greaterThan(reads));
      expect(authorityConfirmed(), isTrue);
      expect(await tapRuns(channel, 'after 503'), isTrue);
    });
  });

  group('the transport', () {
    test('6, 24. half-open 15 s, 7 s after a PING: suspended 6 s after the '
        'cut, before the transport\'s disconnect at 13 s; recovered on '
        'reconnection', () async {
      final (peer, channel) = await reachActiveAssistance();
      await pings(1); // t = 10 s: the last PING
      await elapse(s(7)); // the cut
      await elapse(s(6) - ms(1));
      expect(authorityConfirmed(), isTrue);
      await elapse(ms(1)); // 13 s after the PING
      expectSuspendedAndKept(peer);
      // The transport's own ping timeout, 20 s after the PING.
      await elapse(s(7));
      await client.emit(const RealtimeDisconnected());
      await settle();
      expect(realtimeBloc.state, isA<DeviceRealtimeReconnecting>());
      expectSuspendedAndKept(peer);

      // The network is back 15 s after the cut; the transport reconnects.
      await elapse(s(2));
      await connectSocket();
      expect(authorityConfirmed(), isTrue);
      expect(joined(), isTrue);
      expect(screenCapture.transmitting, isTrue);
      expect(await tapRuns(channel, 'back'), isTrue);
    });

    test('25. half-open 25 s, 1 s after a PING: suspended at 12 s of the cut, '
        '7 s before the transport noticed', () async {
      final (peer, _) = await reachActiveAssistance();
      await pings(1);
      await elapse(s(1)); // the cut
      await elapse(s(12));
      expectSuspendedAndKept(peer);
      await elapse(s(7));
      await client.emit(const RealtimeDisconnected());
      await settle();
      await elapse(s(5));
      await connectSocket();
      expect(authorityConfirmed(), isTrue);
    });

    test('26. receives but cannot send: PINGs keep coming until the server '
        'gives up; then suspended 13 s after the last one, 7 s before the '
        'transport', () async {
      final (peer, _) = await reachActiveAssistance();
      // The PONGs are lost: the server sends its next PING 10 s after the
      // last PONG it received and closes 10 s after that. The tablet has
      // received PING n; the server never gets its PONG.
      await pings(1);
      await elapse(s(13));
      expectSuspendedAndKept(peer);
      expect(realtimeBloc.state, isA<DeviceRealtimeHeartbeatOverdue>());
    });

    test('8-9. a reconnection while the old deadline is pending: the old '
        'connection\'s timer suspends nothing', () async {
      final (_, channel) = await reachActiveAssistance();
      await elapse(s(11));
      await client.emit(const RealtimeDisconnected());
      await settle();
      await connectSocket();
      expect(authorityConfirmed(), isTrue);
      await elapse(s(12)); // 23 s after the first connection
      expect(authorityConfirmed(), isTrue);
      expect(await tapRuns(channel, 'new socket'), isTrue);
      await elapse(s(1)); // 13 s after the new one
      expect(suspended(), isTrue);
    });

    test('7. a PING after the transport gave up does not bring the channel '
        'back', () async {
      final (peer, _) = await reachActiveAssistance();
      await elapse(s(13));
      await client.emit(const RealtimeDisconnected());
      await settle();
      await ping(); // late callback of what was the socket
      expect(realtimeBloc.state, isA<DeviceRealtimeReconnecting>());
      expectSuspendedAndKept(peer);
    });

    test('15. a transport that never gives up: a new socket at 25 s; without '
        'a connection the 75 s grace ends the session here, with no close '
        'sent', () async {
      final (_, _) = await reachActiveAssistance();
      await elapse(s(13));
      expect(suspended(), isTrue);
      final sockets = client.connectedWithTokens.length;
      await elapse(s(12));
      expect(client.connectedWithTokens, hasLength(sockets + 1));
      expect(realtimeBloc.state, isA<DeviceRealtimeReconnecting>());

      // Nothing ever connects. 75 s after the suspension, not after the stall.
      await elapse(
        RemoteSessionBloc.defaultAuthorityGracePeriod - s(12) - ms(1),
      );
      expect(suspended(), isTrue);
      await elapse(ms(1));
      expect(remoteSessionBloc.state, isA<RemoteSessionEndedLocally>());
      expect(screenCapture.isActive, isFalse);
      expect(remoteSessionRepository.closedIds, isEmpty);
    });

    test('23. a 5 s micro-cut that holds back no PING past 13 s: nothing '
        'happens', () async {
      final (_, channel) = await reachActiveAssistance();
      await pings(1);
      // Cut from 4 s to 9 s after the PING: the next one, due at ~10 s,
      // arrives on time.
      await pings(1, every: ms(10200));
      expect(authorityConfirmed(), isTrue);
      expect(await tapRuns(channel, 'after the micro-cut'), isTrue);
    });

    test('23b. a 5 s micro-cut that holds a PING back to 14 s: suspended for '
        'one round trip, then recovered without a new consent', () async {
      final (peer, channel) = await reachActiveAssistance();
      await pings(1);
      // Cut from 9 s to 14 s: the PING sent at 10 s is delivered at 14 s.
      await elapse(s(14));
      expectSuspendedAndKept(peer);
      await ping();
      expect(authorityConfirmed(), isTrue);
      expect(joined(), isTrue);
      expect(screenCapture.dialogs, [testRemoteSessionId]);
      expect(await tapRuns(channel, 'after'), isTrue);
    });

    test('27. several cuts in a row: no timer or watch of an earlier one is '
        'left, each recovery needs its own read', () async {
      final (peer, channel) = await reachActiveAssistance();
      for (var round = 0; round < 3; round++) {
        await elapse(s(13));
        expectSuspendedAndKept(peer);
        final reads = remoteSessionRepository.currentCount;
        await ping();
        expect(remoteSessionRepository.currentCount, greaterThan(reads));
        expect(authorityConfirmed(), isTrue);
        expect(await tapRuns(channel, 'round $round'), isTrue);
      }
      // A transport loss and a reconnection on top.
      await client.emit(const RealtimeDisconnected());
      await settle();
      await connectSocket();
      expect(authorityConfirmed(), isTrue);
      await pings(5);
      expect(authorityConfirmed(), isTrue);
      expect(timers.pending.where((t) => t.dueAt > timers.now + s(13)), isEmpty,
          reason: 'no deadline beyond the current watch');
    });
  });

  group('ends that win', () {
    test('20. FINALIZAR while overdue: ended here at once and for good; a '
        'later PING brings nothing back', () async {
      final (peer, channel) = await reachActiveAssistance();
      await elapse(s(13));
      remoteSessionBloc.add(const RemoteSessionCloseRequested());
      await settle();
      expect(remoteSessionBloc.state, isNot(isA<RemoteSessionLive>()));
      expect(peer.isClosed, isTrue);
      expect(screenCapture.isActive, isFalse);
      expect(remoteSessionRepository.closedIds, [testRemoteSessionId]);

      remoteSessionRepository.currentResult = activatedRemoteSession;
      await ping();
      await pings(3);
      expect(remoteSessionBloc.state, isNot(isA<RemoteSessionLive>()));
      expect(joined(), isFalse);
      expect(peerFactory.createCount, 1);
      expect(await tapRuns(channel, 'after FINALIZAR'), isFalse);
    });

    test('21. SYSTEM closes it during the reconciliation: closed, no rejoin, '
        'nothing reopened by the PINGs that follow', () async {
      final (peer, _) = await reachActiveAssistance();
      await elapse(s(13));
      remoteSessionRepository.holdReads = true;
      await ping();
      await client.emit(
        const RealtimeRemoteSessionClosed(
          testRemoteSessionId,
          endedBy: 'SYSTEM',
        ),
      );
      await settle();
      expect(remoteSessionBloc.state, isA<RemoteSessionClosedRemotely>());
      expect(peer.isClosed, isTrue);
      expect(screenCapture.isActive, isFalse);

      // The read the PING made answers ACTIVE, late: closed stays closed.
      for (final read in remoteSessionRepository.heldReads) {
        if (!read.isCompleted) read.complete(activatedRemoteSession);
      }
      await settle();
      await pings(2);
      expect(remoteSessionBloc.state, isNot(isA<RemoteSessionLive>()));
      expect(joined(), isFalse);
      expect(remoteSessionRepository.closedIds, isEmpty);
    });

    test('22. a new assistance after it needs a new capture and its own '
        'confirmation', () async {
      await reachActiveAssistance();
      await elapse(s(13));
      remoteSessionRepository.currentResult = noRemoteSession;
      await ping();
      expect(screenCapture.isActive, isFalse);

      remoteSessionRepository.currentResult = const Ok<RemoteSession?>(
        RemoteSession(
          id: testOtherRemoteSessionId,
          supportRequestId: testSupportRequestId,
          status: RemoteSessionStatus.connecting,
          technician: testRemoteSessionTechnician,
        ),
      );
      remoteSessionBloc.add(const RemoteSessionSyncRequested());
      await settle();
      expect(authorityConfirmed(), isTrue);
      await client.deliver(
        offerReceived(remoteSessionId: testOtherRemoteSessionId),
      );
      await settle();
      expect(screenCapture.dialogs, [
        testRemoteSessionId,
        testOtherRemoteSessionId,
      ]);
      // And it is watched like the first: 13 s of silence suspend it.
      await elapse(s(13));
      expect(suspended(), isTrue);
    });
  });

  group('a tablet that runs late', () {
    test('29. the deadline passed while the isolate was blocked: the first '
        'command is refused from the clock, and the suspension follows',
        () async {
      final (peer, channel) = await reachActiveAssistance();
      await elapse(s(10));
      clocksAhead = s(5); // 15 s old, no timer has run
      expect(authorityConfirmed(), isTrue, reason: 'not suspended yet');
      expect(await tapRuns(channel, 'late'), isFalse);
      expect(refusedAsNotActive(channel, 'late'), isTrue);
      // The declaration runs on the isolate's next turn (a zero-delay timer
      // here, fired by moving the manual clock by nothing).
      await elapse(Duration.zero);
      expectSuspendedAndKept(peer);
    });

    test('28. back from the background after a sleep: the heartbeat is '
        'measured again at once', () async {
      final (peer, _) = await reachActiveAssistance();
      await elapse(s(3));
      clocksAhead = s(30);
      watchdog.checkNow(); // what the app does on resume
      await settle();
      timers.elapse(Duration.zero);
      await settle();
      expectSuspendedAndKept(peer);
    });

    test('a touch_move arriving late is refused as well, and the touch is '
        'abandoned by the suspension that follows', () async {
      final (_, channel) = await reachActiveAssistance();
      pushHold(channel);
      await settle();
      accessibility.answerStart();
      await settle();
      final handle =
          (accessibility.touchCalls.last as (String, int, double, double)).$2;
      clocksAhead = s(14);
      channel.pushFrame(
        const WebRtcDataChannelMessage.text(
          '{"v":1,"type":"touch_move","id":"mv-1","touch":"t-1","seq":1,'
          '"x":0.5,"y":0.6}',
        ),
      );
      await settle();
      expect(
        accessibility.touchCalls.whereType<(String, int, int, double, double)>(),
        isEmpty,
      );
      timers.elapse(Duration.zero);
      await settle();
      expect(accessibility.touchCalls, contains(('abandon', handle)));
    });
  });
}
