# remote_control_device

## Project overview

`remote_control_device` is the Flutter Android client installed on tablets and Android devices that can receive assisted remote technical support.

The complete system consists of:

```text
remote_control_backend
    NestJS + PostgreSQL / Neon

remote_control_device
    Flutter Android
    ← this repository

remote_control_web
    Flutter Web
    technician application
```

The final goal is to provide functionality conceptually similar to TeamViewer for Android devices.

Remote access is assisted.

The user of the Android device requests assistance and explicitly authorizes the technician before remote control begins.

---

# Technology

Main technology:

```text
Flutter
Dart
Android
```

Architecture:

```text
DDD
BLoC
```

Keep clear separation between:

```text
data
domain
presentation
```

Do not place HTTP, persistence or business logic directly inside widgets.

---

# Backend contract

The backend is:

```text
remote_control_backend
```

The backend contract is documented locally in:

```text
docs/backend/ENDPOINTS.md
docs/backend/REALTIME.md
```

These files are copies of the official contract maintained in `remote_control_backend`.

Before implementing any backend integration, read the relevant contract file.

Do NOT guess:

* endpoint paths;
* HTTP methods;
* request fields;
* response fields;
* Socket.IO event names;
* ACK structures;
* error codes;
* authentication rules.

If the Flutter implementation requires a backend contract that does not exist, do not silently invent it.

That requires a change in `remote_control_backend`.

The backend remains the source of truth.

Do not modify the copied contract files merely to make the Flutter implementation easier.

---

# Device identity

Each installed Android device is represented by a backend `Device`.

Important identifiers:

## publicId

Human-readable identifier such as:

```text
384-729-142
```

It is an identifier, not authentication.

## deviceId

Backend UUID assigned to the device.

Do not generate it locally.

## deviceSecret

Permanent high-entropy credential issued once during enrollment.

It is sensitive.

Never log it or store it in plaintext.

---

# Enrollment

The device cannot freely register itself.

A technician/admin first creates the device in the backend and generates an enrollment code.

The Android user then enters:

```text
publicId
+
6-digit enrollment code
```

The exact endpoint and payload are defined in:

```text
docs/backend/ENDPOINTS.md
```

A successful enrollment provides:

```text
deviceId
deviceSecret
```

plus the public device information defined by the current backend contract.

The `deviceSecret` is returned only once.

If it is lost or revoked, the device must be enrolled again.

---

# Secure storage

Sensitive credentials must use secure Android-backed storage.

At minimum:

```text
deviceSecret
```

must NEVER be stored in:

```text
SharedPreferences
plain files
SQLite plaintext
logs
debug output
```

Use a maintained Flutter secure-storage mechanism backed by Android Keystore.

Hide the implementation behind a data/infrastructure abstraction.

Domain and presentation code must not depend directly on the secure-storage package.

---

# Device JWT

The device authenticates independently from technicians.

The device uses:

```text
deviceId
+
deviceSecret
```

to obtain a Device JWT.

There is no user login in this application.

Never store technician email/password credentials.

The Device JWT is temporary.

When it expires, authenticate again using the stored permanent device credential.

Do not force re-enrollment only because the Device JWT expired.

If the permanent credential itself is rejected or revoked, transition to a state where re-enrollment is required.

---

# Startup flow

The intended startup flow is:

```text
App starts
    ↓
Read local secure enrollment data
    ↓
Not enrolled?
    ├── yes → enrollment screen
    │
    └── no
         ↓
Authenticate device
         ↓
Validate backend state
         ↓
Ready
```

Do not assume cached authentication state is authoritative.

The backend is authoritative.

---

# HTTP architecture

Do not scatter HTTP calls through widgets or BLoCs.

Prefer a structure conceptually similar to:

```text
RemoteDataSource
      ↓
RepositoryImpl
      ↓
Repository
      ↓
UseCase
      ↓
BLoC
      ↓
UI
```

Use models/DTOs in the data layer and domain entities in the domain layer when appropriate.

Keep the backend base URL configurable.

Do not hardcode URLs across multiple files.

---

# Error handling

Differentiate meaningful categories such as:

```text
network
authentication
validation
server/backend
```

Do not show raw exceptions, stack traces, SQL information or internal backend messages directly to the end user.

Do not make UI business logic depend on human-readable backend error strings when a stable status/code exists.

---

# Device information

Enrollment may send Android/device metadata required by the backend contract, such as:

```text
manufacturer
model
Android version
app version
```

Use appropriate Flutter packages/APIs.

Do not use invasive hardware identifiers such as:

```text
IMEI
serial number
advertising ID
```

as authentication.

Backend enrollment provides device identity.

---

# Socket.IO

Realtime functionality will use the backend namespace:

```text
/devices
```

The exact handshake and events are defined in:

```text
docs/backend/REALTIME.md
```

The socket is authenticated using the Device JWT.

Do not use:

```text
deviceId
publicId
deviceSecret
```

as client-provided socket identity.

The backend derives identity from the validated Device JWT.

Socket.IO will be implemented in a dedicated prompt.

Do not implement it during enrollment/authentication unless explicitly requested.

---

# Presence

The backend considers the device ONLINE while at least one authenticated `/devices` Socket.IO connection is alive.

Flutter does not set `isOnline` manually.

Socket connectivity determines backend presence.

---

# Support flow

The future application flow is:

```text
Ready
  ↓
User requests assistance
  ↓
WAITING
  ↓
Technician assigned
  ↓
User explicitly accepts or rejects
  ↓
RemoteSession
```

Never automatically accept a technician.

Realtime notifications are not the sole source of truth.

After reconnect/restart, recover current state from backend REST endpoints when the contract provides them.

---

# RemoteSession

A future remote session progresses conceptually:

```text
CONNECTING
ACTIVE
CLOSED
```

The device must only operate on sessions belonging to its authenticated backend identity.

Do not trust arbitrary `remoteSessionId` values without backend validation.

---

# Signaling

The backend already supports WebRTC signaling over Socket.IO.

Current signaling contracts are defined in:

```text
docs/backend/REALTIME.md
```

Relevant concepts include:

```text
remote-session:join
webrtc:offer
webrtc:answer
webrtc:ice-candidate
```

Do not implement signaling until its dedicated prompt.

---

# WebRTC

WebRTC will eventually connect:

```text
remote_control_device
        ↕
remote_control_web
```

Expected future transport:

```text
VideoTrack
    Device → Web

RTCDataChannel
    Web ↔ Device
```

NestJS is used only for signaling/control-plane communication.

Screen video should not normally travel through NestJS.

---

# Android native integration

The project is Flutter, but remote control requires Android-native APIs.

Kotlin may be added inside the Flutter Android project when needed.

Expected future native functionality includes:

```text
MediaProjection
ForegroundService
AccessibilityService
possibly DevicePolicyManager
```

Keep native code isolated behind a clear Flutter/native boundary such as:

```text
MethodChannel
EventChannel
internal plugin
```

Do not move normal application business logic to Kotlin.

---

# MediaProjection

Screen capture will later use Android MediaProjection.

Remote support is intentionally assisted.

Do not attempt to bypass Android's screen-sharing authorization.

Do not implement MediaProjection until explicitly requested.

---

# AccessibilityService

Remote interaction will later use Android-native accessibility functionality.

Expected future commands include:

```text
tap
long press
swipe
drag
scroll
Back
Home
Recent apps
text input
```

Do not implement AccessibilityService before its dedicated prompt.

---

# Kiosk mode

Kiosk / Device Owner is not required for the initial remote-control implementation.

The application must first work on a normal Android device.

Possible future functionality:

```text
Device Owner
Lock Task Mode
maintenance mode
```

Do not implement kiosk functionality unless explicitly requested.

---

# Logging

Never log:

```text
deviceSecret
Device JWT
enrollment code
SDP contents
ICE candidate contents
```

Be careful with HTTP interceptors and Socket.IO debug logs that may expose complete payloads or authorization headers.

Safe operational identifiers such as `publicId` or `remoteSessionId` may be logged when useful.

---

# Security principles

This application will eventually allow a technician to control the Android device remotely.

Treat these as security boundaries:

```text
enrollment
device authentication
support authorization
RemoteSession ownership
signaling
remote control
```

Never:

```text
trust IDs supplied by the UI as authorization
store credentials in plaintext
automatically accept assistance
bypass backend ownership checks
silently begin remote control
```

---

# Scope discipline

Development is intentionally incremental.

Implement only the functionality explicitly requested by the current prompt.

Do not proactively add:

```text
Socket.IO
SupportRequest
RemoteSession
WebRTC
MediaProjection
AccessibilityService
kiosk
```

before their corresponding prompts.

Small, testable changes are preferred.

---

# Verification

Normally run:

```text
flutter analyze
```

Run additional relevant tests/build checks when appropriate.

When Kotlin/native Android code is introduced, verify the Android build.

Never claim something was tested on a physical tablet unless it actually was.

Clearly distinguish between:

```text
unit test
widget test
emulator
physical Android device
```

---

# Project prompt convention

This project is:

```text
remote_control_device
```

Every development prompt must contain:

```text
Proyecto: remote_control_device
Prompt: <incremental number>
```

The title goes on the following line.

Example:

```text
Proyecto: remote_control_device
Prompt: 1

# remote_control_device — Prompt 1 — FLUTTER — Enrolamiento y autenticación persistente
```

Its numbering is independent from:

```text
remote_control_backend
remote_control_web
```

---

# Planned development order

Approximate roadmap:

```text
1. Enrollment + persistent device authentication
2. Socket.IO /devices + reconnection
3. SupportRequest flow
4. RemoteSession recovery/lifecycle
5. Signaling
6. WebRTC peer connection
7. MediaProjection
8. Remote screen video
9. RTCDataChannel
10. AccessibilityService remote control
11. Lifecycle/security hardening
12. Optional kiosk / Device Owner
```

This roadmap does not authorize implementing future steps early.

---

# Priority

If instructions conflict, follow:

```text
current explicit prompt
        ↓
actual repository state
        ↓
docs/backend contract
        ↓
CLAUDE.md background
```

The current development prompt is authoritative for its scope.
