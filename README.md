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

## VS Code Run/Debug

[.vscode/launch.json](.vscode/launch.json) ships ready-made *Run and Debug*
configurations so the `--dart-define`s above never have to be typed by hand.
Pick one in the Run and Debug view and press F5; it runs `lib/main.dart` on the
device currently selected in VS Code:

```text
remote_control_device - Dev Tunnel         backend behind a VS Code Dev Tunnel
remote_control_device - Local Backend      physical tablet -> NestJS on the LAN
remote_control_device - Android Emulator   emulator -> host machine via 10.0.2.2
remote_control_device - Release            flutter run --release, production URL
```

`Release` runs a release build on the selected device with the production
`https://` URL (placeholder `api.example.com`); there is no debugger or hot
reload in that mode. It does not produce the distributable APK, which is still
built from the command line as shown above.

`Local Backend` carries a placeholder IP (`192.168.1.100`); replace it with the
LAN address of the machine running `remote_control_backend`. `localhost`,
`127.0.0.1` and `10.0.2.2` do not reach the PC from a physical tablet.

When the Dev Tunnel URL changes, edit the `BACKEND_BASE_URL` line of that
configuration in `.vscode/launch.json` and launch again. No Dart code changes,
no configuration assets: the source of the value during debugging is still the
`--dart-define` that VS Code injects. `WEBRTC_STUN_URL` is left empty there on
purpose (host candidates only); it can be filled in the same way later.

Only `launch.json` is versioned; the rest of `.vscode/` is personal and
ignored.

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
