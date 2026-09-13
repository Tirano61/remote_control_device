# remote_control_device

Flutter Android client of the assisted remote-support system. It is installed on
the tablets that can receive remote technical support.

The backend (`remote_control_backend`) is the source of truth; its REST contract
is copied under [docs/backend/ENDPOINTS.md](docs/backend/ENDPOINTS.md).

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
default cleartext block, so a production URL must be `https://`.

## Current scope

Implemented so far (prompt 1):

```text
enrollment  ->  POST /device-enrollment/activate
login       ->  POST /device-auth/login
validation  ->  GET  /device-auth/check-status
```

The permanent `deviceId` + `deviceSecret` live in Android-Keystore-backed secure
storage; the Device JWT is kept in memory only and is re-obtained from the
permanent credential whenever the app restarts.

Not implemented yet: Socket.IO, support requests, remote sessions, signaling,
WebRTC, MediaProjection, AccessibilityService, kiosk mode.

## Checks

```bash
flutter analyze
flutter test
```
