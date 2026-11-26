import 'dart:async';

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
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_transmission.dart';
import 'package:remote_control_device/features/signaling/presentation/bloc/signaling/signaling_bloc.dart';
import 'package:remote_control_device/features/support/domain/usecases/accept_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/cancel_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/load_current_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/reject_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/request_support.dart';
import 'package:remote_control_device/features/support/presentation/bloc/support/support_bloc.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_connection_state.dart';
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

/// Prompt 43, end to end: the native transmission lease against the heartbeat
/// watchdog and every bloc and coordinator, the real ones. The screen capture
/// client is the fake one with its lease switched on: it keeps the deadline
/// under the same rules as `ScreenCaptureTransmission.kt`, on the device's
/// elapsed-realtime clock, which moves with real time whether or not the
/// isolate runs. So "Dart blocked" is the clocks moving with no timer fired and
/// no event handled, and what the technician would see is [FakeScreenCaptureClient.live].
///
/// Built on the Prompt 42 harness: The socket, REST, the peer, the capture and
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

  /// Android's elapsed-realtime clock: an hour since boot, then real time —
  /// the timers' clock plus whatever the isolate missed.
  int realtime() =>
      (const Duration(hours: 1) + timers.now + clocksAhead).inMicroseconds *
      1000;

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
      elapsedRealtimeClock: realtime,
    );
    screenCapture.realtimeNanos = realtime;

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
      transmissionEvidence: watchdog,
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
    expect(screenCapture.live, isTrue);
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

  /// What the technician would get from [count] screen changes made now.
  int sendScreen([int count = 1]) {
    final before = screenCapture.framesSent;
    for (var i = 0; i < count; i++) {
      screenCapture.screenChanged();
    }
    return screenCapture.framesSent - before;
  }

  /// The Dart isolate is held for [duration]: real time passes — the native
  /// clock with it — and no timer fires, no event is handled.
  void holdIsolate(Duration duration) => clocksAhead += duration;

  int nanosOf(Duration duration) => duration.inMicroseconds * 1000;

  group('A. a normal assistance', () {
    test('many heartbeats: the lease is renewed by every PING and never runs '
        'out; one opening, no lapse, every frame sent', () async {
      await reachActiveAssistance();
      final openings = screenCapture.openings.length;
      for (var i = 0; i < 40; i++) {
        await elapse(ms(10000 + (i % 6) * 500)); // 10 s + a varying round trip
        expect(sendScreen(), 1, reason: 'PING $i');
        await ping();
        expect(sendScreen(), 1);
      }
      expect(screenCapture.openings.length, openings);
      expect(
        screenCapture.renewals.map((r) => r.$2),
        everyElement(ScreenTransmissionRenewal.renewed),
      );
      expect(screenCapture.renewals, hasLength(40));
      expect(screenCapture.framesExpired, 0);
      expect(suspended(), isFalse);
    });

    test('the opening runs from the newest evidence, not from the moment it '
        'is made', () async {
      await reachActiveAssistance();
      final evidence = screenCapture.openings.last!;
      expect(evidence.validFor, s(13));
      expect(evidence.channel, watchdog.watch);
      expect(evidence.observedAtNanos, watchdog.currentEvidence!.observedAtNanos);
      expect(evidence.observedAtNanos, lessThanOrEqualTo(realtime()));
    });

    test('a renewal is sent with the PING\'s own instant, however late the '
        'message', () async {
      await reachActiveAssistance();
      await elapse(s(10));
      final at = realtime();
      await ping();
      expect(screenCapture.renewals.last.$1.observedAtNanos, at);
    });
  });

  group('B. half-open', () {
    test('15 s without PING, 7 s after one: frames stop at the native deadline '
        'by themselves, and Dart\'s suspension only follows', () async {
      final (peer, _) = await reachActiveAssistance();
      await elapse(s(7));
      await ping();
      final evidenceAt = realtime();

      // 13 s after the PING, minus a millisecond: still live.
      timers.elapse(s(13) - ms(1));
      expect(screenCapture.live, isTrue);
      // At 13 s: nothing goes through, before any Dart code has run.
      timers.elapse(ms(1));
      expect(realtime() - evidenceAt, nanosOf(s(13)));
      expect(screenCapture.live, isFalse);
      expect(sendScreen(5), 0);
      expect(authorityConfirmed(), isTrue, reason: 'Dart has not run yet');

      // Dart's turn: the watchdog declares it, the session is suspended and
      // the gate is closed here too.
      await settle();
      timers.elapse(Duration.zero);
      await settle();
      expectSuspendedAndKept(peer);
      await elapse(s(2));
      expect(sendScreen(5), 0);
    });
  });

  group('C-D. Dart blocked', () {
    test('C. the isolate held 20 s: the native gate holds every frame back '
        'from 13 s on with no call from Dart at all', () async {
      final (_, _) = await reachActiveAssistance();
      await elapse(s(5));
      await ping(); // newest evidence
      final switches = screenCapture.transmissions.length;
      final renewals = screenCapture.renewals.length;

      holdIsolate(s(12));
      expect(sendScreen(3), 3, reason: '12 s old: still vouched for');
      holdIsolate(s(1));
      expect(sendScreen(3), 0, reason: '13 s old: run out');
      holdIsolate(s(7));
      expect(sendScreen(10), 0);
      expect(screenCapture.framesExpired, 13);

      // Not one message from Dart in the meantime.
      expect(screenCapture.transmissions.length, switches);
      expect(screenCapture.renewals.length, renewals);
      expect(screenCapture.isActive, isTrue, reason: 'MediaProjection kept');
    });

    test('D. resumed with a PING already waiting: it is an unseen lapse, so '
        'the session is suspended and only a REST read made after it reopens '
        'the screen, under a new grant', () async {
      final (peer, channel) = await reachActiveAssistance();
      await elapse(s(5));
      await ping();
      holdIsolate(s(20));
      final openings = screenCapture.openings.length;

      // The PING that waited behind the block is handled first.
      remoteSessionRepository.holdReads = true;
      final readsBefore = remoteSessionRepository.heldReads.length;
      await ping();
      expect(suspended(), isTrue, reason: 'the lapse is not forgiven');
      expect(screenCapture.live, isFalse);
      expect(screenCapture.transmitting, isFalse, reason: 'closed here too');
      expect(screenCapture.openings.length, openings, reason: 'no reopening');
      expect(await tapRuns(channel, 'resumed'), isFalse);
      expect(sendScreen(5), 0);

      // More PINGs do not reopen anything either.
      await pings(2);
      expect(screenCapture.openings.length, openings);
      expect(sendScreen(), 0);

      // The read made after the channel came back confirms it.
      expect(remoteSessionRepository.heldReads.length, greaterThan(readsBefore));
      remoteSessionRepository.heldReads.last.complete(activatedRemoteSession);
      await settle();
      expect(authorityConfirmed(), isTrue);
      expect(joined(), isTrue);
      expect(screenCapture.openings.length, openings + 1);
      expect(screenCapture.live, isTrue);
      expect(sendScreen(), 1);
      expect(screenCapture.dialogs, [testRemoteSessionId], reason: 'no dialog');
      expect(peer.isClosed, isFalse);
      expect(await tapRuns(channel, 'confirmed'), isTrue);
    });

    test('D. resumed with the timer first: the overdue path, the same '
        'outcome', () async {
      final (peer, _) = await reachActiveAssistance();
      await elapse(s(3));
      // Held 5 s, then the timers run 5 s behind real time: the watchdog's
      // check, due 13 s after the connection, runs when it is 18 s old.
      holdIsolate(s(5));
      timers.elapse(s(10) - ms(10)); // real 17.99 s: the check has not run
      expect(screenCapture.live, isFalse);
      expect(authorityConfirmed(), isTrue, reason: 'Dart has not run yet');

      timers.elapse(ms(10)); // the watchdog's pending check runs, late
      await settle();
      timers.elapse(Duration.zero);
      await settle();
      expectSuspendedAndKept(peer);

      final openings = screenCapture.openings.length;
      await ping();
      expect(authorityConfirmed(), isTrue, reason: 'the read answered at once');
      expect(screenCapture.openings.length, openings + 1);
      expect(screenCapture.live, isTrue);
    });

    test('a block shorter than the deadline costs nothing', () async {
      await reachActiveAssistance();
      await elapse(s(2));
      holdIsolate(s(8));
      expect(sendScreen(), 1);
      await ping(); // 10 s gap: continues the chain
      expect(suspended(), isFalse);
      expect(screenCapture.renewals.last.$2, ScreenTransmissionRenewal.renewed);
      expect(sendScreen(), 1);
    });
  });

  group('renewals racing the deadline', () {
    test('7. a timely PING whose renewal reaches the gate after the deadline '
        'resumes the frames without a suspension: the evidence was in time',
        () async {
      await reachActiveAssistance();
      await elapse(s(12) + ms(900));
      screenCapture.renewalGate = Completer<void>();
      await ping(); // in time for Dart, and its instant is in time natively
      timers.elapse(ms(400)); // the message is slow: the lease runs out
      expect(screenCapture.live, isFalse);
      expect(sendScreen(), 0);

      screenCapture.renewalGate!.complete();
      screenCapture.renewalGate = null;
      await settle();
      expect(screenCapture.renewals.last.$2, ScreenTransmissionRenewal.renewed);
      expect(screenCapture.live, isTrue);
      expect(suspended(), isFalse);
      expect(sendScreen(), 1);
    });

    test('15. a renewal held for longer than its evidence vouches is a lapse: '
        'suspended, and reopened only after a REST read', () async {
      final (peer, _) = await reachActiveAssistance();
      await elapse(s(10));
      screenCapture.renewalGate = Completer<void>();
      await ping();
      final openings = screenCapture.openings.length;

      // The message waits 14 s. Dart's watchdog declares nothing: it has the
      // PING, 10 s apart from the previous one... until its own deadline.
      timers.elapse(s(12));
      remoteSessionRepository.holdReads = true;
      screenCapture.renewalGate!.complete();
      screenCapture.renewalGate = null;
      timers.elapse(s(2));
      await settle();
      expect(screenCapture.renewals.last.$2, ScreenTransmissionRenewal.lapsed);
      await settle();
      timers.elapse(Duration.zero);
      await settle();
      expectSuspendedAndKept(peer);
      await ping();
      expect(screenCapture.openings.length, openings);
      remoteSessionRepository.heldReads.last.complete(activatedRemoteSession);
      await settle();
      expect(screenCapture.openings.length, openings + 1);
      expect(screenCapture.live, isTrue);
    });

    test('a lapse only the Android side saw is reported to the watchdog: '
        'overdue, suspended, confirmed again before anything is sent',
        () async {
      final (peer, channel) = await reachActiveAssistance();
      await elapse(s(10));
      screenCapture.lapseNextRenewal = true;
      remoteSessionRepository.holdReads = true;
      await ping();
      timers.elapse(Duration.zero);
      await settle();

      expect(watchdog.isOverdue, isTrue);
      expectSuspendedAndKept(peer);
      expect(await tapRuns(channel, 'after the lapse'), isFalse);
      final openings = screenCapture.openings.length;

      await elapse(s(10));
      await ping(); // ends the overdue: a new chain, not a reopening
      expect(screenCapture.openings.length, openings);
      remoteSessionRepository.heldReads.last.complete(activatedRemoteSession);
      await settle();
      expect(authorityConfirmed(), isTrue);
      expect(screenCapture.openings.length, openings + 1);
      expect(screenCapture.live, isTrue);
    });

    test('a lapse answer about an opening already replaced changes nothing',
        () async {
      await reachActiveAssistance();
      await elapse(s(10));
      screenCapture.renewalGate = Completer<void>();
      screenCapture.lapseNextRenewal = true;
      await ping();
      // Meanwhile the authority is suspended and confirmed again: a new
      // opening replaces the one the renewal was for.
      await elapse(s(13));
      await ping();
      expect(authorityConfirmed(), isTrue);
      final openings = screenCapture.openings.length;
      screenCapture.renewalGate!.complete();
      screenCapture.renewalGate = null;
      await settle();
      expect(screenCapture.openings.length, openings);
      expect(suspended(), isFalse);
      expect(screenCapture.transmitting, isTrue);
    });
  });

  group('generations', () {
    test('1-2. a new socket: the old one\'s chain renews nothing, the new grant '
        'carries the new connection', () async {
      await reachActiveAssistance();
      final oldWatch = watchdog.watch;
      await client.emit(const RealtimeDisconnected());
      await settle();
      expect(screenCapture.transmitting, isFalse);
      await elapse(s(1));
      await connectSocket();
      expect(authorityConfirmed(), isTrue);
      expect(screenCapture.openings.last!.channel, watchdog.watch);
      expect(screenCapture.openings.last!.channel, isNot(oldWatch));
      await pings(2);
      expect(
        screenCapture.renewals.map((r) => r.$1.channel).toSet(),
        {watchdog.watch},
      );
      expect(screenCapture.live, isTrue);
    });

    test('12-13. two cuts and two recoveries: each recovery a new opening '
        'after its own read, never a renewal across a cut', () async {
      final (peer, _) = await reachActiveAssistance();
      for (var cut = 0; cut < 2; cut++) {
        await elapse(s(13));
        expectSuspendedAndKept(peer);
        final openings = screenCapture.openings.length;
        await elapse(s(2));
        await ping();
        expect(screenCapture.openings.length, openings + 1);
        expect(screenCapture.live, isTrue);
        await pings(2);
        expect(screenCapture.live, isTrue);
      }
      expect(screenCapture.dialogs, [testRemoteSessionId]);
    });

    test('9-10. a recovery offer replaces the peer, not the lease: the same '
        'capture, the same opening, still renewed', () async {
      final (peer, _) = await reachActiveAssistance();
      final openings = screenCapture.openings.length;
      await client.deliver(offerReceived(sdp: testSecondOfferSdp));
      await settle();
      expect(peer.isClosed, isTrue);
      expect(peerFactory.createCount, 2);
      await pings(3);
      expect(screenCapture.openings.length, openings);
      expect(screenCapture.live, isTrue);
      expect(screenCapture.dialogs, [testRemoteSessionId]);
    });
  });

  group('ends that win over any renewal', () {
    test('5, 9. FINALIZAR while a renewal is on its way: the capture is gone '
        'and the renewal reaches nothing', () async {
      await reachActiveAssistance();
      await elapse(s(10));
      screenCapture.renewalGate = Completer<void>();
      await ping();
      remoteSessionBloc.add(const RemoteSessionCloseRequested());
      await settle();
      expect(screenCapture.isActive, isFalse);

      screenCapture.renewalGate!.complete();
      screenCapture.renewalGate = null;
      await settle();
      expect(screenCapture.renewals.last.$2, ScreenTransmissionRenewal.ignored);
      await pings(2);
      expect(screenCapture.live, isFalse);
      expect(remoteSessionBloc.state, isNot(isA<RemoteSessionLive>()));
    });

    test('6, 10. SYSTEM during the recovery: closed for good, no PING or late '
        'read reopens video', () async {
      await reachActiveAssistance();
      await elapse(s(13));
      remoteSessionRepository.holdReads = true;
      await ping();
      final openings = screenCapture.openings.length;
      await client.emit(
        const RealtimeRemoteSessionClosed(
          testRemoteSessionId,
          endedBy: 'SYSTEM',
        ),
      );
      await settle();
      expect(remoteSessionBloc.state, isA<RemoteSessionClosedRemotely>());
      expect(screenCapture.isActive, isFalse);
      for (final read in remoteSessionRepository.heldReads) {
        if (!read.isCompleted) read.complete(activatedRemoteSession);
      }
      await settle();
      await pings(3);
      expect(screenCapture.openings.length, openings);
      expect(screenCapture.live, isFalse);
    });

    test('8, 16. Android stops MediaProjection while a renewal is on its way: '
        'nothing is renewed or restarted', () async {
      await reachActiveAssistance();
      await elapse(s(10));
      screenCapture.renewalGate = Completer<void>();
      await ping();
      screenCapture.endFromPlatform();
      await settle();
      screenCapture.renewalGate!.complete();
      screenCapture.renewalGate = null;
      await settle();
      expect(screenCapture.renewals.last.$2, ScreenTransmissionRenewal.ignored);
      await pings(2);
      expect(screenCapture.isActive, isFalse);
      expect(screenCapture.dialogs, [testRemoteSessionId]);
    });

    test('11. a new assistance: a new capture, a new opening from the evidence '
        'of the moment, watched like the first', () async {
      await reachActiveAssistance();
      remoteSessionBloc.add(const RemoteSessionCloseRequested());
      await settle();
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
      await elapse(s(4));
      await client.deliver(
        offerReceived(remoteSessionId: testOtherRemoteSessionId),
      );
      await settle();
      expect(screenCapture.dialogs, [
        testRemoteSessionId,
        testOtherRemoteSessionId,
      ]);
      expect(screenCapture.live, isTrue);
      expect(
        screenCapture.openings.last!.observedAtNanos,
        watchdog.currentEvidence!.observedAtNanos,
      );
      // 4 s already gone on that evidence: it runs out 9 s from now.
      timers.elapse(s(9) - ms(1));
      expect(screenCapture.live, isTrue);
      timers.elapse(ms(1));
      expect(screenCapture.live, isFalse);
    });
  });
}
