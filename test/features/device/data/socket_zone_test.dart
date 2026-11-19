import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/device/data/realtime/socket_zone.dart';
import 'package:web_socket/web_socket.dart' show WebSocketConnectionClosed;

/// `socket_io_client` 3.1.6 closes its WebSocket without awaiting the close:
/// when the server had already closed it, the future fails with
/// [WebSocketConnectionClosed] and nobody listens. Seen on every
/// server-initiated disconnection (Prompt 34, scenarios F1/G2).
void main() {
  /// Runs [body] under a parent zone that records what reaches it, which is
  /// what the application's root zone would have received.
  Future<List<Object>> uncaughtReachingParent(void Function() body) async {
    final reached = <Object>[];
    await runZoned(
      () async {
        body();
        await pumpEventQueue();
      },
      zoneSpecification: ZoneSpecification(
        handleUncaughtError: (self, parent, zone, error, stackTrace) =>
            reached.add(error),
      ),
    );
    return reached;
  }

  test('the unawaited close of an already-closed WebSocket is absorbed', () async {
    var absorbed = 0;
    final reached = await uncaughtReachingParent(
      () => runInSocketZone(
        // What WebSocketTransport.doClose() leaves behind.
        () => unawaited(Future<void>.error(WebSocketConnectionClosed())),
        onTransportAlreadyClosed: () => absorbed++,
      ),
    );

    expect(absorbed, 1);
    expect(reached, isEmpty);
  });

  test('a callback scheduled by the package later still runs in the zone', () async {
    var absorbed = 0;
    late void Function() later;
    final reached = await uncaughtReachingParent(() {
      runInSocketZone(
        // A listener registered while connecting, fired by a later packet.
        () => later = Zone.current.bindCallback(
          () => unawaited(Future<void>.error(WebSocketConnectionClosed())),
        ),
        onTransportAlreadyClosed: () => absorbed++,
      );
      later();
    });

    expect(absorbed, 1);
    expect(reached, isEmpty);
  });

  test('any other asynchronous error is forwarded, not silenced', () async {
    var absorbed = 0;
    final reached = await uncaughtReachingParent(
      () => runInSocketZone(
        () => unawaited(Future<void>.error(StateError('a real bug'))),
        onTransportAlreadyClosed: () => absorbed++,
      ),
    );

    expect(absorbed, 0);
    expect(reached, [isA<StateError>()]);
  });

  test('synchronous exceptions still reach the caller', () {
    expect(
      () => runInSocketZone<void>(
        () => throw ArgumentError('bad url'),
        onTransportAlreadyClosed: () {},
      ),
      throwsArgumentError,
    );
  });

  test('the body result is returned unchanged', () {
    expect(
      runInSocketZone(() => 42, onTransportAlreadyClosed: () {}),
      42,
    );
  });
}
