import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:remote_control_device/core/config/app_config.dart';

/// Event the backend emits to a socket right after a successful handshake.
const String deviceConnectedEvent = 'device:connected';

/// Event the backend emits when a technician takes this device's support
/// request. It carries no authority of its own: see `RealtimeSupportAssigned`.
const String supportAssignedEvent = 'support:assigned';

/// Event the backend emits, after `POST /remote-sessions` commits, to say that
/// a remote session now exists for this device. A cue to re-read REST, never a
/// session in itself: see `RealtimeRemoteSessionCreated`.
const String remoteSessionCreatedEvent = 'remote-session:created';

/// Event the backend emits, after `POST /remote-sessions/:id/activate` commits,
/// to say that the session really moved `CONNECTING -> ACTIVE`. The technician
/// reports the connection; the backend writes `ACTIVE` and `connectedAt`.
///
/// Emitted only on the real transition — a retried activation emits nothing —
/// and, like every other notice here, it is a cue to re-read REST and never a
/// state in itself: see `RealtimeRemoteSessionActivated`.
const String remoteSessionActiveEvent = 'remote-session:active';

/// Event the backend emits when the *technician* closes the session. A
/// device-initiated close emits nothing — the closing side already holds the
/// closed session in its HTTP response.
const String remoteSessionClosedEvent = 'remote-session:closed';

/// Handshake options for the `/devices` namespace.
///
/// Everything that decides *who* the connection is comes from a single place:
///
/// ```json
/// { "auth": { "token": "<Device JWT>" } }
/// ```
///
/// `REALTIME.md` is explicit that the backend reads nothing else — a
/// `deviceId`, `publicId` or `deviceSecret` sent in the handshake or in any
/// payload authenticates nothing — so none of them is ever put on the wire
/// here. The `deviceSecret` in particular never leaves HTTPS: it is only ever
/// posted to `/device-auth/login`.
///
/// Transport: **websocket only**. The Android client is not a browser, so the
/// HTTP long-polling phase of the default upgrade dance buys nothing: it only
/// adds a round trip, a second handshake to authenticate, and a requirement for
/// sticky sessions once the backend runs on more than one instance. The cost is
/// that a network which blocks WebSocket upgrades (some corporate proxies) has
/// no fallback; that is an acceptable trade for a tablet on a normal network,
/// and it is a one-line change here if it ever stops being true.
///
/// Auto-connect is disabled so that listeners can be attached before the first
/// attempt. Connecting is then an explicit `connect()`, which is what keeps a
/// single connection from producing duplicated listeners and events.
///
/// `forceNew` keeps this socket out of the `socket_io_client` Manager cache.
/// That cache is keyed by scheme/host/port, so without it a later connection to
/// the same backend would silently reuse the Manager built around the *previous*
/// `auth` map — exactly the way an expired Device JWT would outlive its
/// renewal.
Map<String, dynamic> buildDeviceSocketOptions({
  required AppConfig config,
  required String deviceToken,
}) => io.OptionBuilder()
    .setTransports(const ['websocket'])
    .disableAutoConnect()
    .enableForceNew()
    .setAuth({'token': deviceToken})
    .setTimeout(config.realtimeConnectTimeout.inMilliseconds)
    .setReconnectionDelay(config.realtimeReconnectionDelay.inMilliseconds)
    .setReconnectionDelayMax(config.realtimeReconnectionDelayMax.inMilliseconds)
    .build();
