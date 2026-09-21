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
        │  it is running
3.  getDisplayMedia                          the capture itself
        │
4.  VideoTrack
```

Every other arrangement is refused by the platform, natively:

* a `mediaProjection` foreground service started **before** consent throws,
  because the app holds no projection to justify the type;
* a capture started **before** the service is running throws a
  `SecurityException` from `MediaProjectionManager.getMediaProjection`.

`MediaProjection` is not a permanent permission. Each capture is a session the
user consents to, and a token is granted for one capture. This application
never stores one, never reuses one across remote sessions, and never tries to
resurrect one after a capture has ended.

## Where each step lives

```text
MediaProjectionScreenCaptureClient          the order, the reuse, the cleanup
  ├── ScreenCaptureConsent                  Helper.requestCapturePermission
  ├── MediaProjectionForegroundService      MethodChannel -> Kotlin Service
  └── ScreenMediaSource                     navigator.mediaDevices.getDisplayMedia
```

The client is ordinary Dart and holds every decision, so the order, the reuse
rule and the cleanup are unit tested against fakes. The three adapters behind
it are as thin as they can be made, because they are the part only a tablet can
verify.

### What `flutter_webrtc 1.6.2+hotfix.2` actually provides

Read out of the installed package rather than remembered:

```text
Helper.requestCapturePermission({bool fullScreenOnly = false}) -> Future<bool>
    shows MediaProjectionManager.createScreenCaptureIntent()
    stores the granted Intent in GetUserMediaImpl.mediaProjectionData
    fullScreenOnly -> MediaProjectionConfig.createConfigForDefaultDisplay()
                      on API 34+, which removes the "share one app" option

navigator.mediaDevices.getDisplayMedia(constraints) -> Future<MediaStream>
    reuses that stored Intent when there is one, and only shows the dialog
    itself when there is not
```

So the plugin already owns the projection token and already reuses it for the
next `getDisplayMedia`. This application therefore does **not** run a
`MediaProjectionManager` of its own — a second one would mean two consent
dialogs for one share. What the plugin does *not* do is run a foreground
service; that obligation is Android 14's and it is ours.

The constraints asked for are exactly:

```dart
{'video': true, 'audio': false}
```

No audio, ever. No width, height or frame rate either: the Android capturer
already matches the display and picks its own rate, and pinning numbers before
a capture has been watched working on these tablets would be guessing at a
trade-off nobody has measured.

`fullScreenOnly: true` is deliberate for this product. A technician assisting
someone on a tablet is walking them through the device, not through one app,
and a single-app share goes black the moment the user leaves it — which reads
as a broken session rather than as a choice they made.

## Answering an offer

```text
setRemoteDescription(offer)          the offer's m=video becomes a transceiver
    │
flush queued remote ICE
    │
prepare screen capture               consent -> service -> getDisplayMedia
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

"Stopped" means all of it: the track stopped, the stream disposed, the
foreground service stopped, the notification gone. No notification outlives the
assistance it belonged to.

## When the user stops the share from Android

Android's own controls can end a `MediaProjection` at any moment. The capture
client listens for it and, if told, releases everything and goes inactive — and
does nothing else. The remote session stays open, the control channel stays
open, and nothing renegotiates. What to offer the user afterwards is a product
question this build does not answer.

**Known limitation.** `flutter_webrtc 1.6.2+hotfix.2` never raises an `ended`
event from native Android code, and the `MediaProjection.Callback.onStop` it
installs deliberately does nothing. So on a real tablet this is *not* currently
detected: frames stop, the session carries on, and the notification goes away
with the session rather than with the capture. The listener is attached anyway
— it costs nothing and is correct the day the plugin starts raising it.

## The foreground service

`MediaProjectionForegroundService.kt`, ~100 lines, and deliberately dull:

* creates a notification channel (API 26+, `IMPORTANCE_LOW`);
* `startForeground(id, notification, FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)`
  on API 29+, so the type is named in the call as well as in the manifest —
  naming only one of the two is the mistake that throws on Android 14;
* holds an ongoing, non-dismissable notification: *Asistencia remota* /
  *Compartiendo pantalla*;
* `START_NOT_STICKY`, because a capture cannot outlive the process granted it;
* `stopForeground(STOP_FOREGROUND_REMOVE)` on destroy.

No WebRTC, no Socket.IO, no session state, no identity. `MainActivity` registers
the channel and nothing else.

Both calls are idempotent where the answer actually lives: starting a running
service re-enters `onStartCommand` and changes nothing, and `stopService` on a
service that is not running is a no-op.

```text
Flutter                                      Android
MethodChannelMediaProjectionForegroundService
  remote_control_device/media_projection  ──> MediaProjectionChannel
    startMediaProjectionForegroundService       MediaProjectionForegroundService.start
    stopMediaProjectionForegroundService        MediaProjectionForegroundService.stop
```

A platform refusal — `ForegroundServiceStartNotAllowedException`,
`SecurityException` — comes back as a `PlatformException`. It has to be
visible: a bridge that swallowed it would let a capture begin with no service,
which is a native crash moments later.

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
[screen] foreground service started
[screen] capture started / reused / stopped
[webrtc] video track attached
```

Never: frames, SDP, ICE candidate lines, projection tokens, platform exception
messages — an Android error string here can quote the capture intent, and a
libwebrtc one can quote the SDP it choked on.
