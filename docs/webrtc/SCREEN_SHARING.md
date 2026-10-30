# Screen sharing — `remote_control_device`

How the tablet's screen reaches the technician, and why the order it happens in
is not negotiable.

This is a local design document. The backend contracts it sits on top of are
[docs/backend/REALTIME.md](../backend/REALTIME.md) (`remote-session:join`,
`webrtc:offer`, `webrtc:answer`, `webrtc:ice-candidate`) and
[docs/backend/ENDPOINTS.md](../backend/ENDPOINTS.md). Nothing here changes
either: the backend relays signaling and never sees a frame.

## The two ends

```text
remote_control_web                      remote_control_device
─────────────────────                   ─────────────────────
offerer                                 answerer
creates the "control" DataChannel       receives it
creates a VIDEO transceiver, recvonly   fills it, sendonly
                                        MediaProjection
```

The roles are fixed. One offerer means there is never an offer collision to
resolve, and the device having no `createOffer` and no `createDataChannel` in
its port makes that unrepresentable rather than merely discouraged.

Video travels peer to peer. NestJS is the control plane — it introduces the two
ends and relays SDP and ICE — and the screen never passes through it.

```text
VIDEO   device ──────────────> web        (sendonly / recvonly)
DATA    web  <──"control"──>  device      (open, carries nothing yet)
```

`remote_control_web` does not render the video yet. This stage ends with a
track being sent and a connection that stays up.

## The order Android 14 requires

The single most important thing in this document:

```text
1.  request screen capture permission        MediaProjection consent dialog
        │  the user accepts
2.  start the foreground service             type = mediaProjection
        │  Android confirms it: READY
3.  start the capture                        ScreenCapturer.kt
        │
4.  VideoTrack
```

Every other arrangement is refused by the platform, natively:

* a `mediaProjection` foreground service started **before** consent throws,
  because the app holds no projection to justify the type;
* a capture started **before** the service is running throws a
  `SecurityException` from `MediaProjectionManager.getMediaProjection`.

"Running" means `startForeground(..., MEDIA_PROJECTION)` has returned inside
the service, **not** that `startForegroundService()` has returned. The second
only queues the service; `onStartCommand` runs later on the main thread. A
capture opened in that gap fails with

```text
SecurityException: Media projections require a foreground service of type
FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
```

which was seen on the tablet, intermittently, on a second consecutive session.
So step 2 completes on the service's own READY (see
[The foreground service](#the-foreground-service)), and nothing in the
application waits on a timer instead.

`MediaProjection` is not a permanent permission. Each capture is a session the
user consents to, and a token is granted for one capture. This application
never stores one, never reuses one across remote sessions, and never tries to
resurrect one after a capture has ended.

## Where each step lives

```text
MediaProjectionScreenCaptureClient          the order, the reuse, the cleanup
  ├── ScreenCaptureConsent                  MethodChannel -> consent dialog
  ├── MediaProjectionForegroundService      MethodChannel -> Kotlin Service, READY
  └── ScreenMediaSource                     MethodChannel -> ScreenCapturer.kt
```

The client is ordinary Dart and holds every decision, so the order, the reuse
rule, the readiness wait and the cleanup are unit tested against fakes. The
adapters behind it are as thin as they can be made, because they are the part
only a tablet can verify. The capture geometry is the exception: it is pure
Kotlin and is unit tested on the JVM (`ScreenCaptureGeometryTest`).

### Why the capture is not `getDisplayMedia`

Read out of the installed `flutter_webrtc 1.6.2+hotfix.2`
(`GetUserMediaImpl.getDisplayMedia`, `OrientationAwareScreenCapturer`):

```text
getDisplayMedia
    Display.getRealSize(size)                 the CURRENT size: 1280x800 sideways
    capturer.startCapture(size.x, size.y)

OrientationAwareScreenCapturer.startCapture
    if !portrait: width = height; height = width    swapped AGAIN -> 800x1280
    mediaProjection.createVirtualDisplay(800, 1280)

onFrame (every frame)
    portrait? = getRealMetrics().height > width
    if the size "changed": changeCaptureFormat(1280, 800)
        -> VirtualDisplay.resize(1280, 800) + setSurface(new Surface)
```

The capturer assumes it is given the natural (portrait) size and is given the
current one, so in landscape it creates the virtual display the wrong way round
and fixes it with a resize on the first frame. The tablet's own system log
shows exactly that:

```text
Display device added:   "WebRTC_ScreenCapture" 800 x 1280
Display device changed: "WebRTC_ScreenCapture" 1280 x 800   (~100 ms later)
```

and what reached the web — verified on the raw `<video>` frame copied to a
canvas — was the left 62.5 % of the screen (800 / 1280) stretched 1.6×. The
platform kept mirroring for the size the display was created with. Android 14
allows **one** `createVirtualDisplay` per projection, so the plugin has no way
round this except the same resize, and every rotation during a session goes
through it too. None of it is reachable from Dart, and none of it can be fixed
on the receiving side without inventing the 37.5 % that was never sent.

### `ScreenCapturer.kt`

```text
startCapture
    read the display now              Display.getRealMetrics, default display
    side = max(width, height)         1280 on this tablet
    createVirtualDisplay(side, side)  once; never resized
onFrame
    crop to where the picture is      TextureBuffer.cropAndScale, no copy
                                      portrait  -> 800x1280 at (240, 0)
                                      landscape -> 1280x800 at (0, 240)
rotation (display listener + configuration change)
    re-read the display; move the crop if the reading moved
```

Android mirrors a display into a projection's virtual display by scaling it to
fit without distortion and centring it (`ContentRecorder` on Android 14,
`LogicalDisplay` before). A square whose side is the screen's longer side holds
it at exactly 1:1 in either orientation, so the picture is never scaled and a
rotation only moves it. `ScreenCaptureGeometry.contentIn` is that same
arithmetic, rounding included, which is what makes the crop land on the picture
and not on the bars around it.

Rotation, then, changes nothing but the crop: the same virtual display, the
same capturer, the same `VideoSource`, the same `VideoTrack` on the same
transceiver. The frames change size inside the track — 800×1280 ↔ 1280×800 —
which libwebrtc encodes without renegotiation and which the web already renders
without recreating its renderer. There is no second peer connection, no second
transceiver, no second track.

#### Noticing a rotation

Two signals, because one was not enough on the tablet:

```text
DisplayListener.onDisplayChanged     arrives first; the display reading is
                                     still the OLD orientation
Application onConfigurationChanged   arrives after; the reading is the new one
```

`Display.getRealMetrics` / `getRotation`, read from the application context,
are adjusted by the application's `Configuration`, and Android updates that
after it has told display listeners about the change. With the display
listener alone the crop stayed one rotation behind — physically, 14:28 rotated
to portrait and nothing moved, 14:30 rotated to landscape and the portrait crop
was applied. So the capturer also registers `ComponentCallbacks2` on the
application context, and **every** signal reads the display afresh
(`ScreenCaptureGeometryRefresh`). A stale reading equals the current state and
moves nothing, so it is never final; the configuration change then moves the
crop; duplicate signals are no-ops. No timers. The tablet's log names the
signal that carried each rotation: `capture geometry … (configuration
changed)`.

What it costs: the virtual display is 1280×1280 rather than 1280×800, a little
more composition per frame, and a frame or two straddling a rotation may be
cropped with the previous orientation's rectangle before the configuration
change arrives.

Dimensions come from `Display.getRealMetrics` on the default display. It is
deprecated in favour of `WindowMetrics` for sizing an app's window; that is not
this. `WindowMetrics` needs a visual context and describes a window, while the
capture runs from the application context — the user is expected to be in
another app — and needs the whole display, which is what the platform mirrors.
`MediaQuery` and any hard-coded size were never options.

### Reaching the plugin

The track still has to be a `flutter_webrtc` track: the peer connection
adapter hands its id to `RTCRtpSender.replaceTrack`, and the plugin resolves it
in its own table of local tracks. So `ScreenCaptureSession.kt` builds the
`VideoSource` and `VideoTrack` with the plugin's own `PeerConnectionFactory`
and EGL context, and registers the track with
`MethodCallHandlerImpl.putLocalTrack`. That handler is a private field of
`FlutterWebRTCPlugin`, read by reflection in `FlutterWebRtcLocalTracks.kt` —
the one place this application touches plugin internals. If a future version
renames it, the capture fails as a value (`captureRefused`) and the assistance
carries on without the screen. On the Dart side the id is wrapped in the
plugin's `MediaStreamTrackNative`, exactly what `getDisplayMedia` builds.

`org.webrtc` is a `compileOnly` dependency of the app at the plugin's exact
version (`io.github.webrtc-sdk:android:150.7871.01`): the classes that run are
the plugin's.

### Consent

The consent dialog is shown by this application too, because the plugin keeps
its grant in a private field for its own capturer. `MainActivity` shows
`MediaProjectionManager.createScreenCaptureIntent(...)` and
`ScreenCaptureConsentRequester` keeps the grant for exactly one capture: the
capture takes it and it is forgotten. On Android 14+ the intent is built with
`MediaProjectionConfig.createConfigForDefaultDisplay()`, which removes the
"share one app" option — a technician walking someone through their tablet
needs the device, and a single-app share goes black the moment the user leaves
that app. The grant never crosses the channel and is never logged.

Video only, by construction: the Android side creates a `VideoSource` and
nothing else.

## Answering an offer

```text
setRemoteDescription(offer)          the offer's m=video becomes a transceiver
    │
flush queued remote ICE
    │
prepare screen capture               consent -> service READY -> capture
    │  a track exists
attach to the offered transceiver    direction = sendonly, replaceTrack(track)
    │
createAnswer()                       the SDP is written from what is now true
setLocalDescription(answer)
sendAnswer()                         webrtc:answer over Socket.IO /devices
```

The capture step sits **before** `createAnswer` because that is the only place
it can be. `remote_control_web` creates its `recvonly` video transceiver before
offering, so once the offer is applied there is exactly one `m=video` waiting
to be filled; filling it afterwards would produce an answer describing a video
section this end is not sending on, and a second negotiation to correct it.

### Finding the offered transceiver

`RTCRtpTransceiver` in the installed plugin carries no media kind — the Android
side maps a transceiver to `{transceiverId, mid, direction, sender, receiver}`
and nothing more — so the kind is read off `receiver.track.kind`, which
libwebrtc populates while the offer is being applied. The `mid` is no help: it
is `"0"` or `"1"`, an ordering, not a kind.

Then, in this order:

```dart
await transceiver.setDirection(TransceiverDirection.SendOnly);
await transceiver.sender.replaceTrack(screenTrack);
```

### Never a second `m=video`

`addTransceiver(video)` would add a section the web never offered.
`addTrack` would do the same whenever libwebrtc found no free sender to reuse.
Both produce an answer that does not mirror the offer, and the web cannot
receive on either.

The SDP itself is never touched — no string is edited, nothing is reordered, no
line is inserted. The direction and the track are set through the peer
connection and `createAnswer` writes the SDP that follows.

If the applied offer has **no** video section, nothing is invented: the failure
is logged, the capture is released, and the negotiation carries on with the
data channel alone.

## Two lifetimes, kept apart

```text
PeerConnection generation   one negotiation. Replaced whenever the web offers
                            again; several come and go in one assistance.

MediaProjection session     one RemoteSession. Survives a peer connection being
                            rebuilt; does not survive the assistance ending.
```

`MediaProjection` belongs to the `RemoteSession`. That single sentence decides
every case below.

| What happened | Peer connection | Screen capture |
| --- | --- | --- |
| a new offer for the same session | rebuilt | reused, no second dialog |
| the transport failed or closed | torn down | kept running |
| signaling room lost mid-negotiation | torn down | kept running |
| the generation went stale during the consent dialog | already gone | kept, for the negotiation that replaced it |
| the remote session closed, by either end | torn down | stopped |
| a different remote session appeared | torn down | stopped; the next offer asks again |
| the device credential was revoked | torn down | stopped |
| the application closed | torn down | stopped |

"Stopped" means all of it: the track forgotten by the plugin; the capturer,
virtual display, projection, source and texture thread released; the
foreground service stopped; the notification gone. No notification outlives the
assistance it belonged to, and nothing of one session survives into the next:
the grant is single-use, every service start carries its own token, and a
release is keyed by track id so a late one cannot stop the capture that
replaced it.

## When the user stops the share from Android

Android's own controls can end a `MediaProjection` at any moment. The capture
client listens for it and, if told, releases everything and goes inactive — and
does nothing else. The remote session stays open, the control channel stays
open, and nothing renegotiates. What to offer the user afterwards is a product
question this build does not answer.

**Known limitation.** `ScreenCapturer.kt` does handle
`MediaProjection.Callback.onStop`: it releases its virtual display and stops.
But nothing tells Dart yet, so the client is *not* told: frames stop, the
session carries on, and the notification goes away with the session rather than
with the capture. The listener is attached anyway, ready for the day the
Android side raises it.

## The foreground service

`MediaProjectionForegroundService.kt`, deliberately dull:

* creates a notification channel (API 26+, `IMPORTANCE_LOW`);
* `startForeground(id, notification, FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)`
  on API 29+, so the type is named in the call as well as in the manifest —
  naming only one of the two is the mistake that throws on Android 14;
* confirms `foregroundServiceType` includes `mediaProjection`, and only then
  reports **READY**;
* holds an ongoing, non-dismissable notification: *Asistencia remota* /
  *Compartiendo pantalla*;
* `START_NOT_STICKY`, because a capture cannot outlive the process granted it;
* `stopForeground(STOP_FOREGROUND_REMOVE)` on destroy.

No WebRTC, no Socket.IO, no session state, no identity.

### READY

```text
Dart  startMediaProjectionForegroundService ──> MediaProjectionChannel
                                                  Service.start(onReady, onFailed)
                                                    token = n, pending = (n, result)
                                                    startForegroundService(intent + n)
      ... the MethodChannel call is still open ...
                                                  onStartCommand(intent n)
                                                    startForeground(MEDIA_PROJECTION)
                                                    type includes mediaProjection?
                                                    settle(n) -> result.success
Dart  start() completes  ──>  open the capture
```

`MethodChannel.Result` is held until the service answers, so the Dart future
*is* the readiness signal. Every start carries a token of its own and only the
matching `onStartCommand` can answer it; `stop` fails a start still pending, and
so does a newer start. A late answer for an abandoned start finds nothing to
answer. All of this runs on the main thread — the channel handler and the
service lifecycle both do — so there is nothing to synchronise.

If `startForeground` throws, or the type is not `mediaProjection`, the start is
answered with an error, the service stops itself, and the capture is never
opened: `ScreenCaptureUnavailable(foregroundServiceRefused)`, and the
assistance carries on without the screen.

Dart bounds the wait at ten seconds (`foregroundServiceNotReady`). That is a
guard against a bridge that never answers, not a way of waiting: a service that
comes up answers as soon as it is up, and Android itself gives up on a service
that has not reached `startForeground` in about that long.

A `stop()` that arrives while a start is still in progress — the session closed
with the dialog up, or while the service was coming up — abandons that start at
its next step (`cancelled`); it never opens a capture afterwards and never
touches state a later start may own.

### The channel

```text
Flutter                                     Android: MediaProjectionChannel
remote_control_device/media_projection
  requestScreenCaptureConsent    -> bool       consent dialog; grant kept natively
  startMediaProjectionForegroundService       answered on READY
  startScreenCapture             -> map        trackId + geometry
  stopScreenCapture {trackId}                 only that capture
  stopMediaProjectionForegroundService        also fails a pending start
```

Stopping is idempotent where the answer actually lives: `stopService` on a
service that is not running is a no-op, and a capture that is not running has
nothing to release. When the Flutter engine goes away the channel stops the
capture, drops the grant, answers anything still waiting and stops the service.

A platform refusal — `ForegroundServiceStartNotAllowedException`,
`SecurityException` — comes back as a `PlatformException` carrying only the
exception's class name. It has to be visible: a bridge that swallowed it would
let a capture begin with no service.

## Manifest

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION" />

<service
    android:name=".MediaProjectionForegroundService"
    android:exported="false"
    android:foregroundServiceType="mediaProjection" />
```

There is no `CAMERA`, no `RECORD_AUDIO` and no location permission, in the
source manifest or in the merged one. This application shares a screen; it has
nothing to ask a microphone or a camera for, and no way to start one by
mistake. `flutter_webrtc` merges in `BLUETOOTH` (`maxSdkVersion="30"`) and
`MODIFY_AUDIO_SETTINGS` of its own accord; neither records anything.

`POST_NOTIFICATIONS` is **not** requested. On Android 13+ a user who has not
granted it will not see the notification, though the service still runs and
Android's own screen-cast indicator still appears. Asking for it would mean a
second runtime dialog and it is outside this stage.

## State

The success condition of the remote connection is unchanged:

```text
PeerConnection connected  +  control DataChannel open  =  WebRTC usable
```

Screen capture is a separate axis — `idle`, `requesting`, `active`, `denied`,
`failed` — carried by every `WebRtcSessionState`, including the idle one, since
a capture outlives an abandoned negotiation. It never decides whether a
`RemoteSession` is `ACTIVE`, and it never widens the condition above: a user who
declined the Android dialog has a technician connected and a control channel
open.

On screen it is one discreet line and never the headline:

```text
Pantalla: esperando autorización
Pantalla: compartiendo
Pantalla: permiso rechazado
Pantalla: error al compartir
```

Android's own dialog and its persistent notification are what actually tell the
user their screen is shared; this line only agrees with them. There is no
button: the permission dialog and the "stop sharing" control belong to the
system, and duplicating either would offer a second way to do something the
system already does better.

## When the screen may be captured

Never at startup, never at device authentication, never when the socket
connects, never on `support:assigned`, and never before a `RemoteSession`
exists. All four of these have to hold first:

```text
the user accepted the SupportRequest
the backend holds a live RemoteSession
a valid webrtc:offer arrived for that session
the user granted Android's MediaProjection consent
```

## Logging

Allowed, and what the code actually prints:

```text
[screen] capture permission requested
[screen] capture permission granted / denied
[screen] media projection service starting / ready
[screen] capture starting / started / reused / stopped
[screen] capture geometry 1280x800 landscape rotation=90 dpi=160
         virtualDisplay=1280 sending=1280x800
[webrtc] video track attached
```

and natively, under the logcat tag `RemoteControlScreen`, once per event and
never per frame:

```text
media projection service starting / ready
screen capture permission granted / denied
capture starting / started / stopped
capture geometry 800x1280 portrait rotation=0 dpi=160,
    virtual display 1280x1280, sending 800x1280@(240,0)
capture geometry 1280x800 landscape rotation=90 dpi=160,
    sending 1280x800@(0,240)                          (on each rotation)
```

`adb logcat -s RemoteControlScreen` is enough to check on the tablet that a
landscape capture sends 1280×800 from (0, 240).

Never: frames, SDP, ICE candidate lines, projection tokens, platform exception
messages — an Android error string here can quote the capture intent, and a
libwebrtc one can quote the SDP it choked on.
