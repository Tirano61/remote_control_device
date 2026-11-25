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

/// A third `RTCPeerConnection` of the web: another origin than [testSdp] and
/// [testSecondOfferSdp].
const String testThirdOfferSdp = 'v=0\r\no=- 88888 2 IN IP4 127.0.0.1\r\n';

/// Prompt 41 (D1), end to end: what a late `/current` answer used to do to a
/// recovery. Every bloc and coordinator is the real one; the network is faked
/// and every remote-session read is held until the test answers it.
///
/// The chain D1 broke, and that these tests follow link by link:
///
/// ```text
/// socket drops ─> suspended, video held, room left
/// socket back  ─> fresh read confirms ─> room joined again
/// web offers   ─> accepted, the same capture on the new peer
///                 ─> video and commands again
/// ```
///
/// On the T10A (S2), an older read answering last put the session back to
/// suspended between the second and the third line: the room was left again,
/// the web's offer found nobody, and after 20 s without a receiver the screen
/// capture stopped and had to be granted again.
void main() {
  late FakeDeviceRealtimeClient client;
  late FakeRemoteSessionRepository remoteSessionRepository;
  late FakeEndedRemoteSessionStore endedSessionStore;
  late FakeWebRtcPeerConnectionFactory peerFactory;
  late FakeScreenCaptureClient screenCapture;
  late FakeRemoteControlAccessibilityClient accessibility;
  late DeviceCredentialRevocation credentialRevocation;
  late ManualTimers timers;

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

  /// Control obeys right now: a tap reaches Android.
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

  bool joined() => signalingBloc.state is SignalingJoined;

  /// An assistance in full swing: socket up, room joined, peer connected,
  /// control channel open, screen shared and transmitted, session ACTIVE.
  Future<(FakeWebRtcPeerConnection, FakeWebRtcDataChannel)>
  reachActiveAssistance() async {
    remoteSessionRepository.currentResult = connectingRemoteSession;
    sessionBloc.add(const DeviceSessionStarted());
    await settle();
    realtimeBloc.add(const DeviceRealtimeStartRequested());
    await settle();
    await client.emit(const RealtimeConnected());
    await settle();

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
    expect(screenCapture.transmitting, isTrue);
    expect(await tapRuns(channel, 'before'), isTrue);
    return (peer, channel);
  }

  /// Answers the [index]-th remote-session read still held (0 = oldest).
  Future<void> answer(int index, Result<RemoteSession?> result) async {
    remoteSessionRepository.heldReads[index].complete(result);
    await settle();
  }

  /// S2 on the T10A, up to the socket's return: Wi-Fi off, the socket drops
  /// at once (Android destroys it), a re-read leaves while the network is
  /// still out and stays on the wire, the device's peer gives up (ICE
  /// `failed`), and the socket comes back with a read of its own.
  ///
  /// Read 0 is the re-read made during the suspension; read 1 the
  /// reconnection's.
  Future<FakeWebRtcPeerConnection> s2UntilTheSocketIsBack() async {
    final (peer, _) = await reachActiveAssistance();
    remoteSessionRepository.holdReads = true;

    await client.emit(const RealtimeDisconnected());
    await settle();
    expect(authorityConfirmed(), isFalse);
    expect(joined(), isFalse);
    expect(screenCapture.transmitting, isFalse);

    await elapse(const Duration(seconds: 2));
    expect(remoteSessionRepository.heldReads, hasLength(1));

    peer.pushConnectionState(WebRtcConnectionState.failed);
    await settle();
    expect(screenCapture.isActive, isTrue, reason: 'kept for the recovery');

    await client.emit(const RealtimeConnected());
    await settle();
    expect(remoteSessionRepository.heldReads, hasLength(2));
    expect(authorityConfirmed(), isFalse, reason: 'no read has answered');
    expect(joined(), isFalse, reason: 'no join before confirmation');
    return peer;
  }

  /// The web's recovery: a new `RTCPeerConnection`, a new offer.
  Future<FakeWebRtcPeerConnection> webOffersAgain() async {
    final before = peerFactory.createCount;
    await client.deliver(offerReceived(sdp: testSecondOfferSdp));
    await settle();
    expect(peerFactory.createCount, before + 1, reason: 'offer accepted');
    return peerFactory.last;
  }

  Future<FakeWebRtcDataChannel> connect(FakeWebRtcPeerConnection peer) async {
    peer.pushConnectionState(WebRtcConnectionState.connected);
    final channel = peer.pushDataChannel();
    await settle();
    channel.pushState(WebRtcDataChannelState.open);
    await settle();
    return channel;
  }

  group('Prompt 41. recovery after a micro-cut', () {
    test('13-14, 19. S2 order: the old read answers last; the room stays '
        'joined, the web\'s offer is accepted, the same capture is reused, '
        'and video and commands come back', () async {
      final oldPeer = await s2UntilTheSocketIsBack();
      final joins = client.joinedSessionIds.length;

      // The reconnection's read answers first and confirms: the room is
      // joined again, and the screen may be transmitted again.
      await answer(1, activatedRemoteSession);
      expect(authorityConfirmed(), isTrue);
      expect(joined(), isTrue);
      expect(client.joinedSessionIds, hasLength(joins + 1));

      // The old one answers last. Before Prompt 41 the room was left here.
      await answer(0, activatedRemoteSession);
      expect(authorityConfirmed(), isTrue);
      expect(joined(), isTrue);
      expect(client.joinedSessionIds, hasLength(joins + 1));

      // Some time back in the room, well inside the capture's window.
      await elapse(const Duration(seconds: 15));
      final answers = client.sentAnswers.length;
      final peer = await webOffersAgain();
      expect(client.sentAnswers, hasLength(answers + 1));
      expect(oldPeer.isClosed, isTrue);

      final channel = await connect(peer);
      expect(screenCapture.dialogs, [testRemoteSessionId], reason: 'no dialog');
      expect(screenCapture.stopCount, 0);
      expect(peer.attachedScreenTracks, hasLength(1));
      expect(screenCapture.transmitting, isTrue);
      expect(await tapRuns(channel, 'after'), isTrue);

      // Well past the orphan deadline: the capture has its receiver.
      await elapse(const Duration(seconds: 30));
      expect(screenCapture.isActive, isTrue);
      expect(remoteSessionRepository.closedIds, isEmpty);
    });

    test('B on the T10A: the web\'s first recovery offer is lost while the '
        'tablet is out of the room, its second one comes 32 s after the '
        'rejoin, and it still finds the capture', () async {
      await s2UntilTheSocketIsBack();
      // The web saw its own peer fail and offered at once. The tablet was not
      // in the room: the offer is dropped, and the web waits out its 30 s
      // answer deadline.
      final created = peerFactory.createCount;
      await client.deliver(offerReceived(sdp: testSecondOfferSdp));
      await settle();
      expect(peerFactory.createCount, created);
      // Out of the room for as long as it takes: no window runs meanwhile.
      await elapse(const Duration(seconds: 30));
      expect(screenCapture.isActive, isTrue);

      await answer(1, activatedRemoteSession);
      await answer(0, activatedRemoteSession);
      expect(joined(), isTrue);

      // 08:06:00.757 rejoin, 08:06:32.536 second offer on the T10A.
      await elapse(const Duration(seconds: 32));
      expect(screenCapture.isActive, isTrue);
      await client.deliver(offerReceived(sdp: testThirdOfferSdp));
      await settle();
      expect(peerFactory.createCount, created + 1);
      final channel = await connect(peerFactory.last);
      expect(screenCapture.dialogs, [testRemoteSessionId], reason: 'no dialog');
      expect(screenCapture.transmitting, isTrue);
      expect(await tapRuns(channel, 'after B'), isTrue);
    });

    test('the window still ends a capture nobody takes: in the room, with the '
        'session confirmed, and no offer for 45 s', () async {
      await s2UntilTheSocketIsBack();
      await answer(1, activatedRemoteSession);
      await elapse(
        WebRtcSessionBloc.defaultOrphanCaptureTimeout -
            const Duration(milliseconds: 1),
      );
      expect(screenCapture.isActive, isTrue);
      await elapse(const Duration(milliseconds: 1));
      expect(screenCapture.isActive, isFalse);
      // A later offer is a new consent.
      await client.deliver(offerReceived(sdp: testThirdOfferSdp));
      await settle();
      expect(screenCapture.dialogs, [testRemoteSessionId, testRemoteSessionId]);
    });

    test('out of the room for good: the capture is not kept past the '
        'authority grace', () async {
      await s2UntilTheSocketIsBack();
      await client.emit(const RealtimeDisconnected());
      await settle();
      await elapse(RemoteSessionBloc.defaultAuthorityGracePeriod);
      expect(remoteSessionBloc.state, isA<RemoteSessionEndedLocally>());
      expect(screenCapture.isActive, isFalse);
      expect(remoteSessionRepository.closedIds, isEmpty);
    });

    test('16. the peer the recovery replaced is dead: whatever it still '
        'reports changes nothing', () async {
      final oldPeer = await s2UntilTheSocketIsBack();
      await answer(1, activatedRemoteSession);
      await answer(0, activatedRemoteSession);
      final peer = await webOffersAgain();
      final channel = await connect(peer);

      oldPeer.pushConnectionState(WebRtcConnectionState.connected);
      oldPeer.pushConnectionState(WebRtcConnectionState.failed);
      await settle();
      expect(webRtcBloc.state.isRemoteConnectionEstablished, isTrue);
      expect(peer.isClosed, isFalse);
      expect(await tapRuns(channel, 'new peer'), isTrue);
    });

    test('17-18. video: held for the whole suspension, held again for the '
        'old read\'s answer, reopened only by the confirmation, and kept open '
        'by the late answer', () async {
      await s2UntilTheSocketIsBack();
      screenCapture.screenChanged();
      expect(screenCapture.framesSent, 0);

      // The old read answers first this time, while nothing is confirmed
      // yet: it opens nothing.
      await answer(0, activatedRemoteSession);
      expect(screenCapture.transmitting, isFalse);
      expect(authorityConfirmed(), isFalse);

      await answer(1, activatedRemoteSession);
      expect(screenCapture.transmitting, isTrue);

      // And in the S2 order, the late answer does not close it again.
      final mark = screenCapture.transmissions.length;
      remoteSessionBloc.add(const RemoteSessionSyncRequested());
      await settle();
      remoteSessionBloc.add(const RemoteSessionSyncRequested());
      await settle();
      await answer(3, activatedRemoteSession);
      await answer(2, activatedRemoteSession);
      expect(screenCapture.transmissions.skip(mark), isEmpty);
      expect(screenCapture.transmitting, isTrue);
    });

    test('21. consecutive micro-cuts: three drops, reads left behind by each, '
        'and one recovery at the end', () async {
      await reachActiveAssistance();
      remoteSessionRepository.holdReads = true;
      for (var cut = 0; cut < 3; cut++) {
        await client.emit(const RealtimeDisconnected());
        await settle();
        await elapse(const Duration(seconds: 2));
        await client.emit(const RealtimeConnected());
        await settle();
      }
      final reads = remoteSessionRepository.heldReads.length;
      final joins = client.joinedSessionIds.length;

      await answer(reads - 1, activatedRemoteSession);
      expect(joined(), isTrue);
      for (var i = reads - 2; i >= 0; i--) {
        await answer(i, activatedRemoteSession);
      }
      expect(authorityConfirmed(), isTrue);
      expect(joined(), isTrue);
      expect(client.joinedSessionIds, hasLength(joins + 1));

      final peer = await webOffersAgain();
      final channel = await connect(peer);
      expect(await tapRuns(channel, 'after'), isTrue);
      expect(screenCapture.dialogs, [testRemoteSessionId]);
    });
  });

  group('Prompt 41. revocation still wins', () {
    test('15, 20. an offer accepted before a revocation: the proof that the '
        'session is over takes everything down, even from an overtaken read',
        () async {
      await s2UntilTheSocketIsBack();
      await answer(1, activatedRemoteSession);
      final peer = await webOffersAgain();
      final channel = await connect(peer);

      // The old read was served after the backend closed the session.
      await answer(0, noRemoteSession);

      expect(remoteSessionBloc.state, isNot(isA<RemoteSessionLive>()));
      expect(peer.isClosed, isTrue);
      expect(channel.isClosed, isTrue);
      expect(screenCapture.isActive, isFalse);
      expect(joined(), isFalse);
      expect(remoteSessionRepository.closedIds, isEmpty);
    });

    test('an offer arriving after the revocation builds nothing', () async {
      await s2UntilTheSocketIsBack();
      await answer(1, activatedRemoteSession);
      await answer(0, noRemoteSession);
      final created = peerFactory.createCount;

      await client.deliver(offerReceived(sdp: testSecondOfferSdp));
      await settle();
      expect(peerFactory.createCount, created);
      expect(screenCapture.isActive, isFalse);
    });

    test('SYSTEM close during the recovery: the stale ACTIVE answers after it '
        'reopen nothing and keep endedBy SYSTEM', () async {
      await s2UntilTheSocketIsBack();
      await client.emit(
        const RealtimeRemoteSessionClosed(
          testRemoteSessionId,
          endedBy: 'SYSTEM',
        ),
      );
      await settle();
      expect(screenCapture.isActive, isFalse);

      for (var i = 0; i < remoteSessionRepository.heldReads.length; i++) {
        if (!remoteSessionRepository.heldReads[i].isCompleted) {
          await answer(i, activatedRemoteSession);
        }
      }
      final state = remoteSessionBloc.state;
      expect(state, isNot(isA<RemoteSessionLive>()));
      if (state is RemoteSessionClosedRemotely) {
        expect(state.endedBy.name, 'system');
      }
      expect(joined(), isFalse);
      expect(screenCapture.transmitting, isFalse);
      expect(remoteSessionRepository.closedIds, isEmpty);
    });

    test('24. FINALIZAR during the recovery: everything down at once, one '
        'DEVICE close, and the old reads answering ACTIVE change nothing',
        () async {
      await s2UntilTheSocketIsBack();
      await answer(1, activatedRemoteSession);
      remoteSessionRepository.closeResult = closeUnreachable;
      remoteSessionBloc.add(const RemoteSessionCloseRequested());
      await settle();
      expect(remoteSessionBloc.state, isA<RemoteSessionEndedLocally>());
      expect(screenCapture.isActive, isFalse);
      expect(joined(), isFalse);

      await answer(0, activatedRemoteSession);
      expect(remoteSessionBloc.state, isA<RemoteSessionEndedLocally>());
      expect(joined(), isFalse);
      expect(screenCapture.isActive, isFalse);
      expect(remoteSessionRepository.closedIds, [testRemoteSessionId]);
      expect(endedSessionStore.closeOwed, isTrue);
    });

    test('23. a new assistance afterwards asks for the screen again', () async {
      await s2UntilTheSocketIsBack();
      await answer(1, activatedRemoteSession);
      await answer(0, noRemoteSession);
      expect(screenCapture.isActive, isFalse);

      // A new request, a new session.
      remoteSessionBloc.add(const RemoteSessionSyncRequested());
      await settle();
      await answer(
        remoteSessionRepository.heldReads.length - 1,
        const Ok<RemoteSession?>(
          RemoteSession(
            id: testOtherRemoteSessionId,
            supportRequestId: testSupportRequestId,
            status: RemoteSessionStatus.connecting,
            technician: testRemoteSessionTechnician,
          ),
        ),
      );
      expect(authorityConfirmed(), isTrue);
      expect(joined(), isTrue);

      await client.deliver(
        offerReceived(
          remoteSessionId: testOtherRemoteSessionId,
          sdp: testSecondOfferSdp,
        ),
      );
      await settle();
      expect(screenCapture.dialogs, [
        testRemoteSessionId,
        testOtherRemoteSessionId,
      ]);
    });
  });
}
