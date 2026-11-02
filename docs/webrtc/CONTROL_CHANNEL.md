# Control channel — `remote_control_device`

What travels over the `control` DataChannel, and what has to be true before a
message from the technician becomes a touch on the screen.

This is a local design document. It is an agreement between
`remote_control_web` and `remote_control_device`, carried peer to peer: the
backend never sees it, and nothing here changes
[docs/backend/REALTIME.md](../backend/REALTIME.md).

## The channel

```text
label     control
creator   remote_control_web, before it offers
receiver  remote_control_device, through onDataChannel
ordered   true
```

There is no second channel, and the device never creates one. A channel with any
other label is closed on arrival.

Frames are UTF-8 text holding one JSON object. Binary frames are ignored.

## Protocol v1

`tap` and `swipe` are supported.

### `tap` — web to device

```json
{
  "v": 1,
  "type": "tap",
  "id": "tap-123",
  "x": 0.5,
  "y": 0.25
}
```

| Field | Type | Rule |
| --- | --- | --- |
| `v` | integer | `1` |
| `type` | string | `"tap"` |
| `id` | string | non-empty; chosen by the sender and opaque to the device |
| `x` | number | finite, `0.0 <= x <= 1.0` |
| `y` | number | finite, `0.0 <= y <= 1.0` |

```text
coordinates = normalized [0,1] over the whole remote frame
origin      = top-left
x grows right
y grows down
```

They are not CSS pixels. The sender has to subtract any letterboxing around its
`<video>` first, because the frame is what they are relative to.

Out-of-range values are refused, never clamped. Unknown extra fields are ignored.

### `swipe` — web to device

One straight stroke, from a start to a different end.

```json
{
  "v": 1,
  "type": "swipe",
  "id": "swipe-123",
  "startX": 0.5,
  "startY": 0.8,
  "endX": 0.5,
  "endY": 0.2,
  "durationMs": 350
}
```

| Field | Type | Rule |
| --- | --- | --- |
| `v` | integer | `1` |
| `type` | string | `"swipe"` |
| `id` | string | non-empty; chosen by the sender and opaque to the device |
| `startX`, `startY` | number | finite, `0.0 <= value <= 1.0` |
| `endX`, `endY` | number | finite, `0.0 <= value <= 1.0` |
| `durationMs` | integer | required, `50 <= durationMs <= 2000` |

The coordinates are the same as a tap's: normalized `[0,1]` over the whole remote
frame, origin top-left, `x` growing right and `y` growing down.

`durationMs` has no default, because it decides whether this is a fling or a slow
drag. `300.0` is not an integer and is refused.

A swipe whose start equals its end is `invalid_command`. It does not become a tap:
`tap` is the command for that. Curves, several fingers, long presses and strokes
continued across commands do not exist.

The rules on values are a tap's too: refused, never clamped, and unknown extra
fields ignored. The ack is the same, with the same errors.

### `ack` — device to web

Exactly one for each command that has an id, on the same channel.

```json
{ "v": 1, "type": "ack", "id": "tap-123", "ok": true }
```

```json
{ "v": 1, "type": "ack", "id": "tap-123", "ok": false, "error": "accessibility_unavailable" }
```

`ok: true` means Android reported the gesture **completed**, not that it was
requested.

| `error` | Meaning |
| --- | --- |
| `accessibility_unavailable` | the accessibility service is not connected |
| `session_not_active` | no `ACTIVE` remote session for this connection, or it ended while the command was queued |
| `gesture_rejected` | Android cancelled or refused the gesture, too many commands are queued, or a swipe lands on a single pixel of this screen |
| `invalid_command` | malformed, with a readable `id` |
| `unsupported_command` | another `v`, or an unknown `type`, with a readable `id` |

No stack trace or platform message ever goes on the channel. An ack may never
arrive: nothing is sent on a channel that closed or was replaced in the meantime,
so the sender needs its own timeout.

### What gets an answer

An ack needs an id to refer to, so:

| Frame | Result |
| --- | --- |
| binary | ignored |
| broken JSON, including a literal `NaN` | ignored |
| not a JSON object | ignored |
| `id` missing, empty, or not a string | ignored |
| `v` missing or not an integer | `invalid_command` |
| `v` is an integer other than `1` | `unsupported_command`; nothing else is read |
| `type` missing or not a string | `invalid_command` |
| `type` is another string | `unsupported_command` |
| `x`/`y` missing, `null`, strings, infinite (`1e999`), out of range | `invalid_command` |
| `startX`/`startY`/`endX`/`endY` missing, `null`, strings, infinite, out of range | `invalid_command` |
| `durationMs` missing, `null`, a string, a double, below `50`, above `2000` | `invalid_command` |
| a swipe whose start equals its end | `invalid_command` |

## When a command runs

The same for a tap and a swipe. All of these, at the moment it is received:

```text
it came from the current PeerConnection generation
its DataChannel is the accepted "control" channel, and it is open
the RemoteSession is ACTIVE, and is the one this negotiation belongs to
the user has not pressed FINALIZAR ASISTENCIA
```

A command that arrives while the session is `CONNECTING` gets `session_not_active`
and no gesture. The web activates the session once it sees its own connection up,
so it should wait for that before sending.

### Consent

Enabling the accessibility service and authorising an assistance are different
things. The service stays enabled between sessions, so it says nothing about
whether anyone may touch this tablet today. It is **not** one of the conditions
above: what authorises a command is the `ACTIVE` session, which exists only after
the user accepted that technician. Outside one, no gesture runs.

Pressing FINALIZAR ASISTENCIA stops gestures immediately, without waiting for the
backend to confirm the close.

### After it was accepted

Taps and swipes share one queue and run one at a time, in the order they arrived,
because a second `dispatchGesture` would cancel the first. Up to 16 wait, of either
kind; beyond that they are refused with `gesture_rejected`.

```text
tap A, swipe B, tap C    A runs; B waits; A ends; B runs; C waits; B ends; C runs
```

```text
                                     running gesture   queued commands
session leaves ACTIVE                finishes          dropped; session_not_active
channel stops being open             finishes          dropped; no ack possible
peer connection failed or replaced   finishes          dropped; no ack possible
```

A gesture already handed to Android cannot be recalled. Nothing starts after it.

A peer connection replaced for the same session keeps working as before: the next
connection receives commands once its own `control` channel is open.

## On the Android side

```text
RTCDataChannelMessage
    │  RemoteControlChannelCodec            data: the only place JSON exists
    ▼
RemoteControlInboundMessage
    │  WebRtcSessionBloc                    the gate above
    ▼
RemoteControlCommandQueue                   one at a time
    │  RemoteControlAccessibilityClient     port
    │  remote_control/accessibility         MethodChannel
    ▼
RemoteControlAccessibilityService.kt        dispatchGesture
```

### The channel

```text
remote_control/accessibility
  isAccessibilityServiceAvailable  -> bool
  performTap {x, y}                -> "completed" | "cancelled" | "rejected"
                                      | "busy" | "invalid" | "unavailable"
  performSwipe {startX, startY, endX, endY, durationMs}
                                   -> the same answers
  openAccessibilitySettings
  accessibilityServiceAvailabilityChanged (Android to Dart) bool
```

Both are answered from the gesture's `GestureResultCallback`, so the Dart future
is the gesture. Dart gives up after five seconds, as a guard against a bridge that
never answers. The longest swipe takes two, so a valid one finishes well inside
that.

These answers are internal to the bridge and never reach the wire. Dart reduces
them to three outcomes, so the `ack` keeps exactly the errors documented above:

```text
"completed"                                  ok: true
"unavailable", or no bridge                  accessibility_unavailable
"cancelled" "rejected" "busy" "invalid"      gesture_rejected
anything else, or no answer in time          gesture_rejected
```

`busy` only guards against a second `dispatchGesture` cancelling the first. The
queue runs one command at a time, so it should not happen in normal operation.

### From a position to a pixel

Android reads the display when each gesture starts, with
`ScreenCapturer.readDisplayGeometry`: the same reading the capture crops with, so
the two describe one screen, and a rotation between two gestures needs no signal
of its own. A rotation during a swipe does not recalculate its stroke: Android
finishes or cancels what it was given.

```text
pixel = min(floor(normalized * size), size - 1)

1280x800, x=0.5, y=0.25    ->  (640, 200)
1280x800, x=1.0, y=1.0     ->  (1279, 799)
800x1280, x=0.5, y=0.5     ->  (400, 640)

1280x800, swipe (0.5, 0.75) to (0.5, 0.25)    ->  (640, 600) to (640, 200)
```

`1.0` would otherwise land one past the last pixel.

The reading has the limitation described in
[SCREEN_SHARING.md](SCREEN_SHARING.md#noticing-a-rotation): in the instant between
the display changing and the application's configuration catching up, it is still
the previous orientation.

### The gesture

A single stroke at screen coordinates, starting at time zero. No view is involved,
so it lands on whatever is on screen, including other applications.

```text
tap      moveTo(x, y)                                  50 ms
swipe    moveTo(startX, startY), lineTo(endX, endY)    durationMs, unchanged
```

Two different positions can still land on one pixel. Android takes a stroke with
no length for a touch held in place, which would be a long press nobody asked for,
so that swipe does not run. It is answered `"invalid"` on the bridge, and so
`gesture_rejected` on the wire. Only the device can know this, because it depends
on the size of the screen.

### The service

```xml
<service
    android:name=".RemoteControlAccessibilityService"
    android:exported="false"
    android:label="@string/remote_control_accessibility_label"
    android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
    <intent-filter>
        <action android:name="android.accessibilityservice.AccessibilityService" />
    </intent-filter>
    <meta-data
        android:name="android.accessibilityservice"
        android:resource="@xml/accessibility_service_config" />
</service>
```

`BIND_ACCESSIBILITY_SERVICE` is what a *binder* must hold, so only the system can
bind it; it is not a permission this application requests.

`exported="false"` because the system binds it regardless and nothing else needs
to. Android's guide shows `exported="true"` in its example, and that is not a
requirement: on the tablet (Android 14), this exact declaration was listed
in Settings, bound by the system and connected, twice. It is pinned by
`AccessibilityServiceDeclarationTest`, so changing it should be a decision.

`accessibility_service_config.xml` asks for `canPerformGestures` and nothing more:
no event types, no `canRetrieveWindowContent`, no
`flagRetrieveInteractiveWindows`. The service cannot read what is on screen.

Available means connected. If Android disconnects the service, the status becomes
unavailable, a running gesture is answered as cancelled, and later commands get
`accessibility_unavailable`.

### Enabling it

Only the user can, in Android's settings. The application never tries. During an
assistance the panel shows one line:

```text
Control remoto: habilitado
Control remoto: requiere habilitar accesibilidad   [HABILITAR CONTROL REMOTO]
```

The button only opens `Settings.ACTION_ACCESSIBILITY_SETTINGS`. Android tells the
application when the service connects, so the line follows on the way back.

On Android 13+ an APK that was sideloaded through a file manager or browser may
have the service greyed out as a *restricted setting*, until the user allows it
from the application's info screen.

## Testing on a device

### Enabled is not connected

The toggle being on says only that the user enabled the service. It is connected
when all of these agree:

```text
logcat -s RemoteControlInput    accessibility service connected
dumpsys accessibility           the service inside "Bound services:{...}"
the panel                       Control remoto: habilitado
```

The panel's line is rendered from the Dart status, which only moves on what the
Android side reports.

### mobile-mcp and UiAutomation stop the service from running

**Do not use mobile-mcp, or anything else holding a `UiAutomation`, while testing
this service.** `UiAutomation` *"suppresses accessibility services by default"*
(`FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES`), and the helper mobile-mcp leaves on
the device, `com.mobilenext.mobilecli.DeviceServer`, holds one.

Seen on the tablet, with the same `exported="false"` manifest:

```text
helper running    Ui Automation[...] in dumpsys    toggle ON   Bound services:{}
                                                               never connected
helper gone       no Ui Automation in dumpsys      toggle ON   Bound services:{Service[...]}
                                                               connected
```

Nothing reports it. `Binding services` and `Crashed services` stay empty and
nothing appears in the log, so it looks exactly like a broken manifest, and it was
first taken for one. The helper was not put back to confirm the cause, so this
rests on that comparison and on Android's documentation.

The helper outlives the call that started it: it exits by itself after 30 minutes
idle (`--idle-timeout-ms=1800000`). Before any test, check that it is gone:

```text
adb shell ps -A | grep app_process
adb shell dumpsys accessibility | grep "Ui Automation"
```

Both should print nothing. For the same reason, an end-to-end gesture test has to
run without mobile-mcp: with the service suppressed, a command would not reach
`dispatchGesture`. Observe with `adb logcat`, `dumpsys` and
`adb exec-out screencap -p` instead. `adb shell input tap` does not use
`UiAutomation`, and is enough to press this application's own buttons.

### Consent

The toggle and the *full control* dialog are the user's, by hand. They are never
pressed through ADB, `settings put`, mobile-mcp or any other automation, even
during a test. Pressing `HABILITAR CONTROL REMOTO` is fine, since it only opens
Settings.

### What has been seen on a device

`tap` has been validated on the tablet, end to end. `swipe` has not: the web does
not send it yet, so what stands behind it is Dart and JVM unit tests. Those stop at
the stroke handed to the service. The part only a device can show is that
`StrokeDescription` receives it and that Android moves the screen with it.

## Logging

```text
[webrtc] control command received: tap <id>
[webrtc] tap accepted
[webrtc] tap completed <id>
[webrtc] tap rejected <id> (gestureRejected)
[webrtc] control command received: swipe <id>
[webrtc] swipe accepted
[webrtc] swipe completed <id>
[webrtc] swipe rejected <id> (gestureRejected)
[webrtc] control message dropped: it belongs to a previous negotiation
```

and natively, under the logcat tag `RemoteControlInput`:

```text
accessibility service connected / disconnected
tap completed / cancelled / rejected / busy / invalid / unavailable
swipe completed / cancelled / rejected / busy / invalid / unavailable
```

Coordinates are not logged. Never: frames, SDP, ICE lines, tokens, secrets.
