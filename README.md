# remote_control_device

Flutter Android client of the assisted remote-support system. It is installed on
the tablets that can receive remote technical support.

The backend (`remote_control_backend`) is the source of truth; its contracts are
copied under [docs/backend/ENDPOINTS.md](docs/backend/ENDPOINTS.md) (REST) and
[docs/backend/REALTIME.md](docs/backend/REALTIME.md) (Socket.IO).

## Backend base URL

The base URL is the only environment-dependent setting and is injected at
compile time from a single place, [lib/core/config/app_config.dart](lib/core/config/app_config.dart):

```bash
# development (Android emulator reaching the host machine)
flutter run --dart-define=BACKEND_BASE_URL=http://10.0.2.2:3000

# development against a backend on the LAN
flutter run --dart-define=BACKEND_BASE_URL=http://192.168.1.50:3000

# production
flutter build apk --release --dart-define=BACKEND_BASE_URL=https://api.example.com
```

Without the define, the default is `http://10.0.2.2:3000`.

Debug builds allow cleartext `http://` traffic (see
`android/app/src/debug/AndroidManifest.xml`); release builds keep Android's
default cleartext block, so a production URL must be `https://` — and with it
`wss://` for the socket, since the realtime URL is derived from the same value.

The Socket.IO namespace is appended to that base URL, never configured
separately:

```text
BACKEND_BASE_URL + /devices
```

which is the form `socket_io_client` needs, because it reads the namespace from
the URL path.

## Current scope

Implemented so far:

```text
prompt 1
  enrollment  ->  POST /device-enrollment/activate
  login       ->  POST /device-auth/login
  validation  ->  GET  /device-auth/check-status

prompt 2
  presence    ->  Socket.IO namespace /devices
```

The permanent `deviceId` + `deviceSecret` live in Android-Keystore-backed secure
storage; the Device JWT is kept in memory only and is re-obtained from the
permanent credential whenever the app restarts.

Not implemented yet: support requests, remote sessions, signaling, WebRTC,
MediaProjection, AccessibilityService, kiosk mode.

## Realtime presence

The socket opens only once the device session reaches `READY`, and it
authenticates with the Device JWT alone (`auth.token`). The backend reports the
device as `ONLINE` for as long as that socket is alive — presence is never set
by this client.

Two states that look alike are kept apart on purpose:

```text
DeviceSessionBloc    is this installation a valid device?   (HTTP)
DeviceRealtimeBloc   is the channel up right now?           (Socket.IO)
```

A tablet on a weak network loses the second without losing the first. Only the
backend rejecting the *permanent* credential sends a device back to the
activation form.

### Background behaviour

There is no foreground service yet, so Android may suspend the process once the
app leaves the foreground: the socket then drops and the backend reports the
device `OFFLINE` until it is reopened. That is acceptable while the app only
announces presence. Keeping the channel alive in the background belongs to the
remote-support flow, where it actually matters, and will need a
`ForegroundService`.

## Checks

```bash
flutter analyze
flutter test
```
