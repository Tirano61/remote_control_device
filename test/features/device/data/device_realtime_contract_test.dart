import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/config/app_config.dart';
import 'package:remote_control_device/features/device/data/realtime/device_realtime_payloads.dart';
import 'package:remote_control_device/features/device/data/realtime/device_socket_options.dart';
import 'package:remote_control_device/features/signaling/data/signaling_events.dart';

import '../../../fakes/device_fakes.dart';
import '../../../fakes/remote_session_fakes.dart';
import '../../../fakes/support_fakes.dart';

/// Guards the parts of `docs/backend/REALTIME.md` a unit test can actually
/// check: the namespace, what the handshake carries, and how every event on
/// the `/devices` socket is read.
///
/// The signaling payloads, ACK shapes and error codes have their own file,
/// `test/features/signaling/data/signaling_contract_test.dart`; what is
/// checked here is the event vocabulary of the namespace as a whole.
void main() {
  const config = AppConfig(backendBaseUrl: 'http://backend.test:3000');

  group('the /devices event vocabulary', () {
    test('is exactly what the contract lists, spelled as it spells them', () {
      // Received by the device.
      expect(
        const [
          deviceConnectedEvent,
          supportAssignedEvent,
          remoteSessionCreatedEvent,
          remoteSessionActiveEvent,
          remoteSessionClosedEvent,
          webRtcOfferEvent,
          webRtcAnswerEvent,
          webRtcIceCandidateEvent,
        ],
        [
          'device:connected',
          'support:assigned',
          'remote-session:created',
          'remote-session:active',
          'remote-session:closed',
          'webrtc:offer',
          'webrtc:answer',
          'webrtc:ice-candidate',
        ],
      );

      // Sent by the device. "There is no other event the device may send."
      expect(
        const [
          remoteSessionJoinEvent,
          webRtcOfferEvent,
          webRtcAnswerEvent,
          webRtcIceCandidateEvent,
        ],
        [
          'remote-session:join',
          'webrtc:offer',
          'webrtc:answer',
          'webrtc:ice-candidate',
        ],
      );
    });

    test('the three signaling events are shared by both directions', () {
      // The relay is bidirectional and the payload rules are identical either
      // way; only `from`, added by the server, distinguishes them.
      const outbound = [webRtcOfferEvent, webRtcAnswerEvent];
      expect(outbound.toSet().length, outbound.length);
      expect(webRtcOfferEvent, isNot(webRtcAnswerEvent));
    });
  });

  group('namespace URL', () {
    test('is the configured backend URL plus /devices', () {
      expect(config.deviceRealtimeUrl, 'http://backend.test:3000/devices');
    });

    test('does not double the separator on a base URL with a trailing slash', () {
      const withSlash = AppConfig(backendBaseUrl: 'http://backend.test:3000/');
      expect(withSlash.deviceRealtimeUrl, 'http://backend.test:3000/devices');
    });

    test('follows the emulator default without it being repeated anywhere', () {
      expect(
        AppConfig.fromEnvironment().deviceRealtimeUrl,
        '${AppConfig.defaultBackendBaseUrl}/devices',
      );
    });

    test('never points at the technician namespace', () {
      expect(AppConfig.deviceRealtimeNamespace, '/devices');
      expect(config.deviceRealtimeUrl, isNot(contains('/technicians')));
    });
  });

  group('handshake options', () {
    final options = buildDeviceSocketOptions(
      config: config,
      deviceToken: testDeviceJwt,
    );

    test('authenticates with auth.token and nothing else', () {
      expect(options['auth'], {'token': testDeviceJwt});
    });

    test('sends no device identifier and no permanent credential', () {
      // The backend reads identity from the validated token only; anything else
      // on the wire would be both useless and a leak.
      final serialised = options.toString();
      expect(serialised, isNot(contains(testDeviceSecret)));
      expect(serialised, isNot(contains(testDeviceId)));
      expect(serialised, isNot(contains(testPublicId)));
      expect(options.containsKey('query'), isFalse);
      expect(options.containsKey('extraHeaders'), isFalse);
    });

    test('connects manually over websocket only', () {
      expect(options['transports'], ['websocket']);
      expect(options['autoConnect'], isFalse);
    });

    test('opts out of the Manager cache so a stale token cannot be reused', () {
      expect(options['forceNew'], isTrue);
    });

    test('takes its timings from the central configuration', () {
      expect(options['timeout'], config.realtimeConnectTimeout.inMilliseconds);
      expect(
        options['reconnectionDelay'],
        config.realtimeReconnectionDelay.inMilliseconds,
      );
      expect(
        options['reconnectionDelayMax'],
        config.realtimeReconnectionDelayMax.inMilliseconds,
      );
      // Seconds, not milliseconds: a tablet with no network must not spin.
      expect(config.realtimeReconnectionDelay.inMilliseconds, greaterThan(500));
      expect(
        config.realtimeReconnectionDelayMax,
        greaterThanOrEqualTo(config.realtimeReconnectionDelay),
      );
    });

    test('a renewed token produces a different handshake', () {
      final renewed = buildDeviceSocketOptions(
        config: config,
        deviceToken: testRenewedDeviceJwt,
      );
      expect(renewed['auth'], {'token': testRenewedDeviceJwt});
    });
  });

  group('device:connected payload', () {
    test('is read as documented', () {
      final confirmation = parseDeviceConnectedPayload({
        'deviceId': testDeviceId,
        'publicId': testPublicId,
      });

      expect(confirmation, isNotNull);
      expect(confirmation!.deviceId, testDeviceId);
      expect(confirmation.publicId, testPublicId);
      expect(
        confirmation.matches(deviceId: testDeviceId, publicId: testPublicId),
        isTrue,
      );
    });

    test('unexpected shapes are rejected instead of partially accepted', () {
      expect(parseDeviceConnectedPayload(null), isNull);
      expect(parseDeviceConnectedPayload('device:connected'), isNull);
      expect(parseDeviceConnectedPayload(const []), isNull);
      expect(parseDeviceConnectedPayload({'deviceId': testDeviceId}), isNull);
      expect(
        parseDeviceConnectedPayload({'deviceId': 42, 'publicId': testPublicId}),
        isNull,
      );
      expect(
        parseDeviceConnectedPayload({'deviceId': '', 'publicId': testPublicId}),
        isNull,
      );
    });

    test('extra properties do not prevent reading the documented ones', () {
      expect(
        parseDeviceConnectedPayload({
          'deviceId': testDeviceId,
          'publicId': testPublicId,
          'somethingAddedLater': true,
        }),
        isNotNull,
      );
    });
  });

  group('support:assigned payload', () {
    Map<String, dynamic> payload() => <String, dynamic>{
      'supportRequestId': testSupportRequestId,
      'technician': <String, dynamic>{
        'id': testTechnicianId,
        'name': testTechnicianName,
      },
    };

    test('is read as documented, identifiers only', () {
      final signal = parseSupportAssignedPayload(payload());

      expect(signal, isNotNull);
      expect(signal!.supportRequestId, testSupportRequestId);
      expect(signal.technicianId, testTechnicianId);
      // The name is validated and then deliberately dropped: what the user is
      // shown comes from GET /support-requests/current, never from the socket.
      expect(signal.props, isNot(contains(testTechnicianName)));
    });

    test('the event name matches the contract', () {
      expect(supportAssignedEvent, 'support:assigned');
    });

    test('unexpected shapes produce no signal at all', () {
      expect(parseSupportAssignedPayload(null), isNull);
      expect(parseSupportAssignedPayload('support:assigned'), isNull);
      expect(parseSupportAssignedPayload(const []), isNull);
      expect(
        parseSupportAssignedPayload({'supportRequestId': testSupportRequestId}),
        isNull,
      );
      expect(
        parseSupportAssignedPayload({
          'supportRequestId': testSupportRequestId,
          'technician': {'id': testTechnicianId},
        }),
        isNull,
      );
      expect(
        parseSupportAssignedPayload({
          'supportRequestId': '',
          'technician': {'id': testTechnicianId, 'name': testTechnicianName},
        }),
        isNull,
      );
      expect(
        parseSupportAssignedPayload({
          'supportRequestId': testSupportRequestId,
          'technician': {'id': 42, 'name': testTechnicianName},
        }),
        isNull,
      );
    });

    test('carries nothing that could be mistaken for a credential', () {
      final withExtras = payload()
        ..['technician'] = <String, dynamic>{
          'id': testTechnicianId,
          'name': testTechnicianName,
          'email': 'ana@example.test',
          'token': 'should-never-be-read',
        };

      final signal = parseSupportAssignedPayload(withExtras);

      expect(signal, isNotNull);
      expect(signal!.props, [testSupportRequestId, testTechnicianId]);
    });
  });

  group('remote-session:created payload', () {
    Map<String, dynamic> payload() => <String, dynamic>{
      'remoteSessionId': testRemoteSessionId,
      'supportRequestId': testSupportRequestId,
      'technician': <String, dynamic>{
        'id': testTechnicianId,
        'name': testTechnicianName,
      },
    };

    test('is read as documented, identifiers only', () {
      final signal = parseRemoteSessionCreatedPayload(payload());

      expect(signal, isNotNull);
      expect(signal!.remoteSessionId, testRemoteSessionId);
      expect(signal.supportRequestId, testSupportRequestId);
      expect(signal.technicianId, testTechnicianId);
      // The name is validated and then deliberately dropped: what the user is
      // shown comes from GET /device/remote-sessions/current, never from the
      // socket.
      expect(signal.props, isNot(contains(testTechnicianName)));
    });

    test('the event name matches the contract', () {
      expect(remoteSessionCreatedEvent, 'remote-session:created');
    });

    test('unexpected shapes produce no signal at all', () {
      expect(parseRemoteSessionCreatedPayload(null), isNull);
      expect(parseRemoteSessionCreatedPayload('remote-session:created'), isNull);
      expect(parseRemoteSessionCreatedPayload(const []), isNull);
      expect(
        parseRemoteSessionCreatedPayload({
          'remoteSessionId': testRemoteSessionId,
        }),
        isNull,
      );
      expect(
        parseRemoteSessionCreatedPayload(
          payload()..remove('supportRequestId'),
        ),
        isNull,
      );
      expect(
        parseRemoteSessionCreatedPayload(payload()..remove('technician')),
        isNull,
      );
      expect(
        parseRemoteSessionCreatedPayload(
          payload()..['remoteSessionId'] = '',
        ),
        isNull,
      );
      expect(
        parseRemoteSessionCreatedPayload(
          payload()..['remoteSessionId'] = 42,
        ),
        isNull,
      );
      expect(
        parseRemoteSessionCreatedPayload(
          payload()
            ..['technician'] = <String, dynamic>{'id': testTechnicianId},
        ),
        isNull,
      );
    });

    test('extra properties do not prevent reading the documented ones', () {
      final withExtras = payload()..['somethingAddedLater'] = true;
      expect(parseRemoteSessionCreatedPayload(withExtras), isNotNull);
    });

    test('carries nothing that could be mistaken for a credential', () {
      final withExtras = payload()
        ..['technician'] = <String, dynamic>{
          'id': testTechnicianId,
          'name': testTechnicianName,
          'email': 'ana@example.test',
          'token': 'should-never-be-read',
        };

      final signal = parseRemoteSessionCreatedPayload(withExtras);

      expect(signal, isNotNull);
      expect(signal!.props, [
        testRemoteSessionId,
        testSupportRequestId,
        testTechnicianId,
      ]);
    });
  });

  group('remote-session:active payload', () {
    test('is read as documented: one field, and it is the session id', () {
      final signal = parseRemoteSessionActivePayload({
        'remoteSessionId': testRemoteSessionId,
      });

      expect(signal, isNotNull);
      expect(signal!.remoteSessionId, testRemoteSessionId);
      // "The payload is deliberately minimal." Nothing else is carried, and in
      // particular no status and no connectedAt: those come from REST.
      expect(signal.props, [testRemoteSessionId]);
    });

    test('the event name matches the contract', () {
      expect(remoteSessionActiveEvent, 'remote-session:active');
    });

    test('the same event name serves both namespaces', () {
      // `/devices` and `/technicians` receive the same name and the same
      // payload — one contract for one fact — so there is no device-specific
      // spelling to get wrong.
      expect(remoteSessionActiveEvent, isNot(remoteSessionCreatedEvent));
      expect(remoteSessionActiveEvent, isNot(remoteSessionClosedEvent));
    });

    test('a payload carrying more than the contract still reads only the id',
        () {
      // A field the contract does not document is not a reason to refuse the
      // event, and is not a reason to believe it either.
      final signal = parseRemoteSessionActivePayload({
        'remoteSessionId': testRemoteSessionId,
        'status': 'ACTIVE',
        'connectedAt': '2026-03-11T09:34:02.000Z',
      });

      expect(signal, isNotNull);
      expect(signal!.props, [testRemoteSessionId]);
    });

    test('a payload with no usable session id produces no signal', () {
      expect(parseRemoteSessionActivePayload(null), isNull);
      expect(parseRemoteSessionActivePayload('remote-session:active'), isNull);
      expect(parseRemoteSessionActivePayload(const []), isNull);
      expect(parseRemoteSessionActivePayload(const <String, Object?>{}), isNull);
      expect(parseRemoteSessionActivePayload({'remoteSessionId': ''}), isNull);
      expect(parseRemoteSessionActivePayload({'remoteSessionId': 42}), isNull);
      expect(
        parseRemoteSessionActivePayload({'remoteSessionId': null}),
        isNull,
      );
    });
  });

  group('remote-session:closed payload', () {
    test('is read as documented', () {
      final signal = parseRemoteSessionClosedPayload({
        'remoteSessionId': testRemoteSessionId,
        'endedBy': 'TECHNICIAN',
      });

      expect(signal, isNotNull);
      expect(signal!.remoteSessionId, testRemoteSessionId);
      // endedBy is documented, read by nothing here, and deliberately not
      // carried: a value this client does not act on has no business crossing
      // into the domain.
      expect(signal.props, [testRemoteSessionId]);
    });

    test('the event name matches the contract', () {
      expect(remoteSessionClosedEvent, 'remote-session:closed');
    });

    test('an endedBy this build has never seen does not void the event', () {
      // RemoteSessionEndedBy may grow values; refusing the event over a field
      // that changes nothing would leave the tablet stuck on "in progress".
      expect(
        parseRemoteSessionClosedPayload({
          'remoteSessionId': testRemoteSessionId,
          'endedBy': 'SOMETHING_NEW',
        }),
        isNotNull,
      );
      expect(
        parseRemoteSessionClosedPayload({
          'remoteSessionId': testRemoteSessionId,
        }),
        isNotNull,
      );
    });

    test('a payload with no usable session id produces no signal', () {
      expect(parseRemoteSessionClosedPayload(null), isNull);
      expect(parseRemoteSessionClosedPayload('remote-session:closed'), isNull);
      expect(parseRemoteSessionClosedPayload(const []), isNull);
      expect(parseRemoteSessionClosedPayload({'endedBy': 'TECHNICIAN'}), isNull);
      expect(parseRemoteSessionClosedPayload({'remoteSessionId': ''}), isNull);
      expect(parseRemoteSessionClosedPayload({'remoteSessionId': 42}), isNull);
    });
  });

  group('connect_error classification', () {
    test('the generic Unauthorized is recognised in either shape', () {
      expect(isUnauthorizedHandshakeError({'message': 'Unauthorized'}), isTrue);
      expect(isUnauthorizedHandshakeError('Unauthorized'), isTrue);
    });

    test('transport failures are not mistaken for an auth problem', () {
      // Assuming otherwise would make a bad network trigger login attempts.
      expect(isUnauthorizedHandshakeError('timeout'), isFalse);
      expect(isUnauthorizedHandshakeError(null), isFalse);
      expect(isUnauthorizedHandshakeError(Exception('connection refused')), isFalse);
      expect(
        isUnauthorizedHandshakeError({'message': 'xhr poll error'}),
        isFalse,
      );
    });
  });
}
