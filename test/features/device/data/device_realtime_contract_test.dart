import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/config/app_config.dart';
import 'package:remote_control_device/features/device/data/realtime/device_realtime_payloads.dart';
import 'package:remote_control_device/features/device/data/realtime/device_socket_options.dart';

import '../../../fakes/device_fakes.dart';

/// Guards the parts of `docs/backend/REALTIME.md` a unit test can actually
/// check: the namespace, what the handshake carries, and how the one event this
/// prompt handles is read.
void main() {
  const config = AppConfig(backendBaseUrl: 'http://backend.test:3000');

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
