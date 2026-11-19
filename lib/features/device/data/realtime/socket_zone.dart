import 'dart:async';

import 'package:web_socket/web_socket.dart' show WebSocketConnectionClosed;

/// Runs [body] in a zone that absorbs exactly one known-benign failure of
/// `socket_io_client` 3.1.6 and forwards everything else untouched.
///
/// The failure: `WebSocketTransport.doClose()` calls `IOWebSocket.close()`
/// without awaiting or catching the returned future. When the other end has
/// already closed the WebSocket — which is precisely what a server-initiated
/// disconnection is — that future completes with [WebSocketConnectionClosed],
/// and with nobody listening it surfaces as an uncaught asynchronous error.
/// The connection is gone either way; there is nothing left to handle.
///
/// The futures involved are created by the package from callbacks registered
/// while the socket was being built and connected, and from `dispose()`; so
/// both are run through this zone and the package's own work inherits it.
///
/// Anything else — including errors thrown by this application's listeners,
/// which also run in this zone — is handed to the parent zone exactly as if
/// this zone did not exist, so it stays observable. Synchronous exceptions
/// thrown by [body] propagate to the caller as usual.
R runInSocketZone<R>(
  R Function() body, {
  required void Function() onTransportAlreadyClosed,
}) => runZoned(
  body,
  zoneSpecification: ZoneSpecification(
    handleUncaughtError: (self, parent, zone, error, stackTrace) {
      if (error is WebSocketConnectionClosed) {
        onTransportAlreadyClosed();
        return;
      }
      parent.handleUncaughtError(zone, error, stackTrace);
    },
  ),
);
