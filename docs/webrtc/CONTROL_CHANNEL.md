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

| `type` | What it does | On Android |
| --- | --- | --- |
| `tap` | one short touch | `dispatchGesture` |
| `swipe` | one straight stroke | `dispatchGesture` |
| `back` | Android's Back | `performGlobalAction(GLOBAL_ACTION_BACK)` |
| `home` | Android's Home | `performGlobalAction(GLOBAL_ACTION_HOME)` |
| `recents` | Android's Recents | `performGlobalAction(GLOBAL_ACTION_RECENTS)` |
| `set_text` | replaces the content of the focused field | `ACTION_SET_TEXT` on the node with input focus |
| `ime_enter` | runs the IME action the focused field exposes | `ACTION_IME_ENTER` on the node with input focus |

All seven travel on the same channel, get the same `ack`, need the same `ACTIVE`
session and the same accessibility service, and wait in the same queue.

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

### `back`, `home` and `recents` — web to device

```json
{
  "v": 1,
  "type": "back",
  "id": "back-123"
}
```

```json
{
  "v": 1,
  "type": "home",
  "id": "home-123"
}
```

```json
{"v":1,"type":"recents","id":"recents-123"}
```

| Field | Type | Rule |
| --- | --- | --- |
| `v` | integer | `1` |
| `type` | string | `"back"`, `"home"` or `"recents"`, exactly |
| `id` | string | non-empty; chosen by the sender and opaque to the device |

They name no position and no duration, because they are not touches: no
coordinates are needed, and a tap at some corner of the screen is not what they do.
As with the other commands, unknown extra fields are ignored, so an `x` sent along
with a `back` changes nothing.

### `set_text` — web to device

Replaces the whole content of the field that has input focus.

```json
{"v":1,"type":"set_text","id":"text-123","text":"Hola mundo"}
```

| Field | Type | Rule |
| --- | --- | --- |
| `v` | integer | `1` |
| `type` | string | `"set_text"` |
| `id` | string | non-empty; chosen by the sender and opaque to the device |
| `text` | string | required; `0` to `4096` UTF-16 code units |

```text
it replaces    the field's whole content, not an insertion at the cursor
it is not      a key press: no IME, no key events, nothing simulated
empty text     empties the field
the cursor     Android leaves it at the end of the new text
focus          it writes to the field with INPUT focus, and never moves the focus
no video       it does not need MediaProjection on the device
capability     it needs canRetrieveWindowContent, used only while an authorised command runs
```

The limit is in UTF-16 code units because `String.length` counts those in both Dart
and Kotlin, and a browser's `String.length` does too. An emoji such as `👋` counts as
two, and an `ñ` as one. `4097` is `invalid_command`, not truncated.

The text is kept exactly as received: no trimming, no normalization, no change of
case. Accents, emoji, symbols, spaces and line breaks are ordinary content.

It names no field. Which one it reaches is whichever has input focus when it runs, so
the technician taps on the field first. With no valid target it answers
`text_target_unavailable` and does nothing else: it does not ask for focus, and does
not look for another field.

Nothing about the field comes back: not its old content, and not its new content.
See [Text-input privacy boundary](#text-input-privacy-boundary).

Backspace, delete, Tab, arrow keys, cursor movement, selection, copy, paste and the
clipboard do not exist, and neither does an Enter key: the closest thing is
[`ime_enter`](#ime_enter--web-to-device), which is not a key. Their absence is why this
is not called a keyboard. Deleting is done by tapping the keyboard's own key: see
[Backspace and delete](#backspace-and-delete).

### `ime_enter` — web to device

Runs the IME action exposed by the field that has input focus.

```json
{"v":1,"type":"ime_enter","id":"enter-123"}
```

| Field | Type | Rule |
| --- | --- | --- |
| `v` | integer | `1` |
| `type` | string | `"ime_enter"`, exactly |
| `id` | string | non-empty; chosen by the sender and opaque to the device |

There is no `text`, `keyCode`, `actionId`, position or duration. As with every other
command, unknown extra fields are ignored, so a `text` sent along with it neither
writes anything nor turns it into a `set_text`.

**It is not "press Enter".** It does not insert `"\n"` and it does not simulate a key.
It asks the focused field to run the action it declares for the keyboard's action key,
whatever that field decided that is. Depending on the field, that can look like:

```text
Search    Done    Go    Next    Send    an action with no particular name
```

The device does not know which one it will be and does not ask: it does not read the
field's IME options or the action's label. A field that runs a search, one that moves
to the next field, and one that sends a message all answer the same `ok: true`.

```text
focus          the field with INPUT focus, resolved as for set_text; the focus is never moved
target         the focused node must be editable and enabled, or text_target_unavailable
the action     the node must list ACTION_IME_ENTER, or ime_action_unavailable
not a stand-in no KeyEvent, no KEYCODE_ENTER, no "\n", no shell, no clipboard, no IME injection
no video       it does not need MediaProjection on the device
reads nothing  not the value, hint, description or password; only editable, enabled, action ids
```

It may be unavailable on a field that looks like it should have one. Not every
`EditText` exposes `ACTION_IME_ENTER`, a custom view may not, and below Android 11 the
action does not exist at all. In that case the answer is `ime_action_unavailable`,
and nothing else is tried in its place.

`ok: true` means Android accepted `ACTION_IME_ENTER`. It does not mean the search
finished, the form was submitted, the message was sent or the screen changed: the
application reacts on its own time, and may do nothing visible. Only the picture can
show what it did.

### `ack` — device to web

Exactly one for each command that has an id, on the same channel.

```json
{ "v": 1, "type": "ack", "id": "tap-123", "ok": true }
```

```json
{ "v": 1, "type": "ack", "id": "tap-123", "ok": false, "error": "accessibility_unavailable" }
```

```json
{ "v": 1, "type": "ack", "id": "back-123", "ok": true }
```

```json
{ "v": 1, "type": "ack", "id": "back-123", "ok": false, "error": "gesture_rejected" }
```

```json
{ "v": 1, "type": "ack", "id": "recents-123", "ok": true }
```

```json
{ "v": 1, "type": "ack", "id": "recents-123", "ok": false, "error": "gesture_rejected" }
```

```json
{ "v": 1, "type": "ack", "id": "text-123", "ok": true }
```

```json
{ "v": 1, "type": "ack", "id": "text-123", "ok": false, "error": "text_target_unavailable" }
```

```json
{ "v": 1, "type": "ack", "id": "text-123", "ok": false, "error": "text_rejected" }
```

```json
{"v":1,"type":"ack","id":"enter-1","ok":true}
```

```json
{ "v": 1, "type": "ack", "id": "enter-1", "ok": false, "error": "ime_action_unavailable" }
```

```json
{ "v": 1, "type": "ack", "id": "enter-1", "ok": false, "error": "ime_action_rejected" }
```

What `ok: true` promises depends on the command, because Android promises different
things:

```text
tap, swipe             Android reported the gesture completed, not merely that it was requested
back, home, recents    Android accepted the global action
set_text               the focused node accepted ACTION_SET_TEXT
ime_enter              the focused node accepted ACTION_IME_ENTER, and nothing about what it then did
```

The field is not read back, so a `set_text` that was acknowledged does not say what
the field ended up holding. An application may filter what it is given, or cut it to
a length of its own.

`performGlobalAction` returns a boolean and has no callback. A `back`, `home` or
`recents` that was acknowledged may still be animating, and nothing says the screen
ended up anywhere in particular. It may also have had no visible effect: Back with nothing to
go back to, for instance.

| `error` | Meaning |
| --- | --- |
| `accessibility_unavailable` | the accessibility service is not connected |
| `session_not_active` | no `ACTIVE` remote session for this connection, or it ended while the command was queued |
| `gesture_rejected` | Android cancelled or refused the gesture or global action, too many commands are queued, or a swipe lands on a single pixel of this screen |
| `invalid_command` | malformed, with a readable `id` |
| `unsupported_command` | another `v`, or an unknown `type`, with a readable `id` |
| `text_target_unavailable` | a valid `set_text` or `ime_enter` with nowhere to go: no active window, nothing with input focus, or a focused node that is not editable or not enabled |
| `text_rejected` | there was somewhere to write, and `ACTION_SET_TEXT` answered `false`, failed, or could not run because a gesture was in progress |
| `ime_action_unavailable` | an `ime_enter` found an editable, enabled field with input focus that does not list `ACTION_IME_ENTER` |
| `ime_action_rejected` | the field lists `ACTION_IME_ENTER`, and `performAction` answered `false`, failed, or could not run because a gesture was in progress |

`gesture_rejected` is older than `back`, `home` and `recents`, and its name is
narrower than what it now covers. It stays as it is: v1 senders already depend on it, and a new
code would be a change to the protocol for no gain to them.

Too many commands queued is `gesture_rejected` for a `set_text` as well. It is the
queue's answer, the same for every kind of command, and it says nothing about the
field. `text_target_unavailable` is not `invalid_command`: the command was fine and
the screen was not ready for it, so tapping on a field and sending it again can work.

An `ime_enter` with no target reuses `text_target_unavailable`, because the target is
resolved exactly as a `set_text`'s and fails for the same reasons.
`ime_action_unavailable` is different: the field is there and is fine, and simply has
no IME action. Sending it again will not change that. It never becomes
`gesture_rejected`, except for the queue being full, which is the queue's answer for
every command.

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
| `text` missing, `null`, a number, a bool, an object, an array, or over `4096` code units | `invalid_command` |

## When a command runs

The same for every command. All of these, at the moment it is received:

```text
it came from the current PeerConnection generation
its DataChannel is the accepted "control" channel, and it is open
the RemoteSession is ACTIVE, and is the one this negotiation belongs to
the user has not pressed FINALIZAR ASISTENCIA
```

A command that arrives while the session is `CONNECTING` gets `session_not_active`
and does not run. The web activates the session once it sees its own connection up,
so it should wait for that before sending.

The video is not one of the conditions either. If `MediaProjection` was refused or
failed, a `back`, `home`, `recents`, `set_text` or `ime_enter` still runs. A `tap` or `swipe` would
too, though without a picture the technician has little to aim at. Whether the web
offers text input, or `ime_enter`, with no picture is the web's decision: without
one, the technician cannot see which field is focused or what its action did.

### Consent

Enabling the accessibility service and authorising an assistance are different
things. The service stays enabled between sessions, so it says nothing about
whether anyone may touch this tablet today. It is **not** one of the conditions
above: what authorises a command is the `ACTIVE` session, which exists only after
the user accepted that technician. Outside one, no command runs: no gesture, no
Back, no Home, no Recents, no text and no IME action. For a `set_text` or an
`ime_enter` that check comes before the active window is looked at, so outside a
session the window is not looked at either.

Pressing FINALIZAR ASISTENCIA stops commands immediately, without waiting for the
backend to confirm the close.

Starting with `set_text`, the assistance consent UI explicitly discloses remote text
entry. `SupportPanel` shows it above `PERMITIR` and `RECHAZAR`, for that one assistance:
it is not a second consent, and it adds no condition to the ones above. It has to stay
true of what is implemented, which is why it says the field is the one that is selected
rather than the one the user chose (a technician's tap can move the focus), that the text
replaces what was there, and that the exception to not sending a field's content is
whatever the shared picture shows. It makes no promise about password fields.

The same disclosure also names the remote IME action that [`ime_enter`](#ime_enter--web-to-device)
runs, as an ability of its own: using the keyboard action available on the selected
field. It does not call it Enter, because the action need not insert a line, and it
gives Search, Go, Next and Send only as examples, because the field decides which
action it exposes, if any. Like the rest of the disclosure, it is not a second consent,
and it adds no privacy claim beyond the ones above.

### After it was accepted

All commands share one queue and run one at a time, in the order they arrived,
because a second `dispatchGesture` would cancel the first, and a Home must not
start under a swipe that has not finished. Up to 16 wait, of any kind; beyond that
they are refused with `gesture_rejected`.

```text
tap A, swipe B, tap C                   A runs; B waits; A ends; B runs; C waits; B ends; C runs
tap A, swipe B, back C, home D          the same: A, then B, then C, then D
tap, swipe, back, home, recents, tap    the same, in exactly that order
tap, set_text, home                     the same
tap, set_text, ime_enter, home          the same, in exactly that order
```

Nothing is estimated. The queue waits for each answer, however long it takes, so a
command holds the line for as long as it really runs: a swipe for its `durationMs`,
a `back`, `home`, `recents`, `set_text` or `ime_enter` only until Android's call
returns. The next
command then starts at once, while the system may still be animating, so a sender
that wants to tap on what a `home` or `recents` leads to should wait for the picture
to show it.

The same goes for a `tap` and the `set_text` after it. The queue guarantees the
`set_text` does not start before the tap has finished, and its ack has been sent. It
cannot guarantee the application has already moved the focus: the gesture completing
says the touch was delivered, and the application reacts to it on its own time. A
`set_text` sent the instant the tap is acknowledged could find no focus, which is
`text_target_unavailable`, or find it still on the previous field, and replace that
one's content. A sender that wants to be sure should wait for the picture to show the
field focused.

An `ime_enter` after a `set_text` waits for the `set_text` to be answered, so the text
was accepted before the action runs. Whether the application has processed the new
text by then is, again, the application's business.

```text
                                     running gesture   queued commands
session leaves ACTIVE                finishes          dropped; session_not_active
channel stops being open             finishes          dropped; no ack possible
peer connection failed or replaced   finishes          dropped; no ack possible
```

A gesture already handed to Android cannot be recalled. Nothing starts after it.
Queued `back`, `home`, `recents`, `set_text` and `ime_enter` commands are dropped with
the rest, so a queued `set_text` or `ime_enter` never looks at the window once the
session has ended.

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
RemoteControlAccessibilityService.kt        dispatchGesture, performGlobalAction,
                                            ACTION_SET_TEXT, ACTION_IME_ENTER
```

### The channel

```text
remote_control/accessibility
  isAccessibilityServiceAvailable  -> bool
  performTap {x, y}                -> "completed" | "cancelled" | "rejected"
                                      | "busy" | "invalid" | "unavailable"
  performSwipe {startX, startY, endX, endY, durationMs}
                                   -> the same answers
  performBack                      -> "completed" | "rejected" | "busy" | "unavailable"
  performHome                      -> the same answers
  performRecents                   -> the same answers
  performSetText {text}            -> "completed" | "targetUnavailable" | "rejected"
                                      | "busy" | "invalid" | "unavailable"
  performImeEnter                  -> "completed" | "targetUnavailable"
                                      | "actionUnavailable" | "rejected" | "busy"
                                      | "unavailable"
  openAccessibilitySettings
  accessibilityServiceAvailabilityChanged (Android to Dart) bool
```

`performTap` and `performSwipe` are answered from the gesture's
`GestureResultCallback`, so the Dart future is the gesture. `performBack`,
`performHome` and `performRecents` take no arguments, and are answered from what
`performGlobalAction` returns: `"completed"` is `true` and `"rejected"` is `false`. Dart never sees an
Android action code. Dart gives up after five seconds, as a guard against a bridge
that never answers. The longest swipe takes two, so a valid one finishes well inside
that.

`performSetText` carries the text and nothing else: no node id, package or class name,
and no previous value, in either direction. `performImeEnter` carries nothing at all,
and only the outcome comes back.

These answers are internal to the bridge and never reach the wire. Dart reduces
them to a few outcomes, so the `ack` keeps exactly the errors documented above:

```text
"completed"                                  ok: true
"unavailable", or no bridge                  accessibility_unavailable
"cancelled" "rejected" "busy" "invalid"      gesture_rejected
anything else, or no answer in time          gesture_rejected
```

and for `performSetText`:

```text
"completed"                                  ok: true
"unavailable", or no bridge                  accessibility_unavailable
"targetUnavailable"                          text_target_unavailable
"rejected" "busy" "invalid"                  text_rejected
anything else, or no answer in time          text_rejected
```

and for `performImeEnter`:

```text
"completed"                                  ok: true
"unavailable", or no bridge                  accessibility_unavailable
"targetUnavailable"                          text_target_unavailable
"actionUnavailable"                          ime_action_unavailable
"rejected" "busy"                            ime_action_rejected
anything else, or no answer in time          ime_action_rejected
```

`busy` never reaches the wire as such, for this command or any other.

`busy` only guards against a second `dispatchGesture` cancelling the first, and a
global action, a `set_text` or an `ime_enter` starting under a running gesture. The queue runs one
command at a time, so it should not happen in normal operation.

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

### Back, Home and Recents

```text
back       AccessibilityService.performGlobalAction(GLOBAL_ACTION_BACK)
home       AccessibilityService.performGlobalAction(GLOBAL_ACTION_HOME)
recents    AccessibilityService.performGlobalAction(GLOBAL_ACTION_RECENTS)
```

Not a `KeyEvent`, not `input keyevent`, not a gesture at some coordinates, and not an
intent to the launcher. No stroke is built and the display is not read, so they do
not depend on geometry, on rotation or on `MediaProjection`. A `recents` runs with no
video at all, and its `ok: true` confirms only that Android accepted the action, not
that the overview has finished opening.

With the service not connected, `performGlobalAction` is not called and the answer
is `"unavailable"`. The session and the video carry on regardless.

### Text

```text
root  = rootInActiveWindow                    no root            targetUnavailable
node  = root.findFocus(FOCUS_INPUT)           no node            targetUnavailable
node.isEditable && node.isEnabled             otherwise          targetUnavailable
node.performAction(ACTION_SET_TEXT, {         false, or thrown   rejected
  ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE: text
})                                            true               completed
```

Input focus is where the keyboard's text would go. `FOCUS_ACCESSIBILITY` is a screen
reader's cursor, which is another thing and is not used in its place. No
`ACTION_FOCUS` or `ACTION_ACCESSIBILITY_FOCUS` is ever sent.

The focus is resolved afresh for every command. The nodes are released before the
answer goes back, however it went, and no reference to one remains. Releasing does
something below Android 13, where nodes are pooled, and nothing from there on.

`rootInActiveWindow` has no way to ask for less below Android 13, where Android also
fetches part of the hierarchy into this process's cache. From Android 13 the root is
requested with no prefetching, which is what the tablet (Android 14) uses.

These are calls into the focused application, made on Android's main thread like
everything else here. An application that has stopped responding holds them until
Android gives up, and Dart's five-second guard may answer `text_rejected` first. In
that case the queue moves on, and the ack does not say the text could not still land.

### IME action

```text
root  = rootInActiveWindow                    no root            targetUnavailable
node  = root.findFocus(FOCUS_INPUT)           no node            targetUnavailable
node.isEditable && node.isEnabled             otherwise          targetUnavailable
node.actionList has an action whose id is
  AccessibilityAction.ACTION_IME_ENTER.id     otherwise          actionUnavailable
node.performAction(ACTION_IME_ENTER.id)       false, or thrown   rejected
                                              true               completed
```

The target is resolved by the same code as a `set_text`'s, with the same release of
every node and the same root fetched with no prefetching from Android 13. Of the node,
it asks three things: whether it is editable, whether it is enabled, and the ids of
the actions it lists. The labels of those actions are not read.

`ACTION_IME_ENTER` exists from Android 11 (API 30). Below that, no node can list it,
so the answer is `actionUnavailable` without looking further. The tablet runs
Android 14.

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

`accessibility_service_config.xml` asks for `canPerformGestures` and
`canRetrieveWindowContent`, and nothing more: no event types, no flags, no touch
exploration, no key event filtering. `performGlobalAction` requires no capability of
its own, so `back`, `home` and `recents` did not widen this, and added no permission.
`set_text` did, and [Text-input privacy boundary](#text-input-privacy-boundary) says
how far. `ime_enter` uses what `set_text` already declared, and widened nothing.

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

## Text-input privacy boundary

`set_text` is the point at which this service stopped being blind.

Before, the service could perform gestures and global actions, with no way to inspect
the window hierarchy.

Now, it can retrieve the content of the active window, because finding the focused
field requires it. `canRetrieveWindowContent` is declared statically and Android
grants it to the service as a whole: it is not limited to one field or to a session.
**The limits below are this implementation's, not Android's**, and a change to this
code could remove them, which is why they are pinned by tests.

```text
receives no global events    no accessibilityEventTypes; onAccessibilityEvent does nothing
watches no window            the window is looked at only while an authorised set_text
                             or ime_enter runs
sends no content             the ack is ok and an error code, and nothing about the field
persists nothing             no node, text, package or hierarchy is kept after the command
reads nothing for set_text   not the value, the hint, the description, or any other field
reads nothing for ime_enter  only editable, enabled and the ids of the listed actions
```

The window is looked at only as a consequence of a command that passed
[the conditions above](#when-a-command-runs). With the service connected and no
`ACTIVE` session, it is not looked at.

### What backs that up

`RemoteTextNode` and `RemoteTextWindow`, the two types the logic sees, have no member
that returns content, so that path cannot read a field: it would not compile.
`ime_enter` adds `exposesImeEnter` and `imeEnter()` to `RemoteTextNode`, neither of which
returns content, and `RemoteSetTextTest` pins the full member list. The adapters over
real `AccessibilityNodeInfo` objects cannot run on the JVM, so `RemoteSetTextTest` and
`RemoteImeEnterTest` pin their source instead: it reads no text, hint, description or
action label, walks no hierarchy, moves no focus and logs nothing.

What this cannot remove is that a node, once fetched, holds what Android put in it,
inside this process, for as long as the command runs. The code does not read it, and
holds no reference afterwards.

### Password fields

A password field is treated like any other: if it is editable, enabled and accepts the
action, it takes the text. It is not refused for being one.

```text
its current value    never read
the new value        never logged, never returned, never stored
```

The value typed by the technician does travel the `control` channel and through the
bridge, because that is the command. It stays out of `RemoteSetTextCommand.toString()`,
which `Equatable` would otherwise fill with it in debug builds.

### Updating over an earlier consent

Android does not ask again when an update adds this capability. On the tablet, an
`adb install -r` over the previous build left the toggle on, and the service came back
bound with the wider capability, without any dialog. A user who enabled the service
before this version accepted a description that said it did not read window content.
That description has been rewritten, but nothing shows it to them unless they open
Settings. Android will not provide a notice, so the assistance consent does: see
[Consent](#consent).

## Backspace and delete

There is no backspace command, and none should be added for now:

```json
{"v":1,"type":"backspace"}
```

does not exist. It would be `unsupported_command`, like any unknown `type`.

The technician deletes the way a user does: by tapping the ⌫ key of the Android
keyboard, which is part of the shared picture, with an ordinary [`tap`](#tap--web-to-device):

```text
tap  ->  dispatchGesture  ->  the ⌫ key of the keyboard on screen  ->  the IME deletes
```

Nothing on the device knows that the tap was a backspace. It is not part of `set_text` or
`ime_enter`, and it needs nothing from the text path: no node, no input focus lookup.

### Why no command

Every other way to delete in another application's field would widen what this service
can see or touch:

```text
an accessibility action        none exists: no public AccessibilityAction deletes text
read the text + set_text       reading node.text crosses the text-input privacy boundary
select one character + cut     ACTION_CUT puts the deleted text on the user's clipboard
AccessibilityInputConnection   needs flagInputMethodEditor, which hands the service the
                               field's initial text and every cursor and selection change
an IME of our own              replaces the user's keyboard and can see everything typed
an injected KEYCODE_DEL        needs INJECT_EVENTS or shell: not available to this app
```

A tap leaves the deletion to the IME that is in use. It decides what one character is,
including emoji and combining sequences, and what happens to a selection. Nothing here
has to know.

### Privacy

The system reads no text, no cursor and no selection to delete. The tap carries a
position and nothing else, exactly as on any other part of the screen. The technician
judges the result from the picture, as for every other tap. A password field is no
different: its value is not read, and the keyboard deletes from it as it would for the
user.

### Seen on a device

On 2026-11-16, on the T10A (Android 16) with Gboard 18.5.6, in the search field of
Android's Settings, held upright. The text was put in place with `set_text`, and every
deletion was one tap from the web console on the ⌫ key in the picture. Each tap was
acknowledged `ok`, and the effect was judged only from the shared picture:

```text
abc                             ->  ab
abcd                            ->  abc  ->  ab  ->  a  ->  empty
hola mundo, "mundo" selected    ->  hola       (the whole selection was deleted)
Hola 👋                         ->  Hola
a👋🏽                            ->  a          (the emoji and its skin tone together)
a👨‍👩‍👧                            ->  a          (the whole ZWJ sequence)
```

The selection was made with a remote double tap on the word. The field kept its focus
throughout, the keyboard stayed up, and the picture updated after every tap.

### Limits

This is a tap, so it works only as far as a tap can reach the key:

- the keyboard has to be on screen, and the ⌫ key has to be visible in the picture;
- where the key is depends on the keyboard and its layout (Gboard split it on the tablet);
- it has only been seen with Gboard, upright, on one tablet: no other keyboard and no
  landscape layout has been tried, and nothing here claims they behave the same;
- from Android 14, a view marked as data-sensitive can drop gestures from accessibility
  services that are not accessibility tools, which this one is not. A keyboard that
  marked its keys that way could ignore the tap.

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

`tap`, `swipe`, `back` and `home` have been validated on the tablet, end to end, on
builds before `set_text`. The record for `back` and `home` is in `remote_control_web`,
in its `docs/CONTROL_CHANNEL.md`.

`recents` and `set_text` have been validated on the same tablet, on 2026-11-05, from
the web console's own buttons over the control channel. `recents` opened the overview
and was acknowledged `ok`. `set_text` wrote into the focused search field of Android's
Settings, the search ran on what it wrote, and it was acknowledged `ok`.

`ime_enter` has been validated end to end on the T10A (Android 16, API 36), with Gboard,
in the search field of Android's Settings. The technician focused the field with a
remote tap and wrote `wifi` with `set_text`; neither of them ran an IME action on its
own. Only pressing `Acción` in the web console did:

```json
{"v":1,"type":"ime_enter","id":"enter-7"}
{"v":1,"type":"ack","id":"enter-7","ok":true}
```

The ack arrived about 62 ms later. Since `ok: true` does not say what the application
did, the effect was checked on the picture: Settings ran the search and closed the
keyboard.

Two of its errors were also seen on the tablet: `text_target_unavailable` with nothing
to write to, and `accessibility_unavailable` with the service disabled.
`ime_action_unavailable` was not reproduced on a device; it is covered by tests only.

Do not stand in for the web with `adb shell input keyevent`: that exercises none of this
path. No debug path exists to send a `set_text` or an `ime_enter`, and none should be
added: it would be a way to write text, or submit a form, that no session authorised.

What has been seen, on the tablet (Android 14), is the declaration taking effect. After
`adb install -r`, with no helper holding a `UiAutomation`:

```text
dumpsys accessibility, before    capabilities=32, eventTypes=
dumpsys accessibility, after     capabilities=33, eventTypes=
logcat -s RemoteControlInput     accessibility service connected
```

`33` is `CAPABILITY_CAN_PERFORM_GESTURES` (`32`) plus
`CAPABILITY_CAN_RETRIEVE_WINDOW_CONTENT` (`1`). The empty `eventTypes` is what no global
events looks like. The service did not need to be enabled again.

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
[webrtc] control command received: back <id>
[webrtc] back accepted
[webrtc] back accepted by android <id>
[webrtc] back rejected <id> (gestureRejected)
[webrtc] control command received: home <id>
[webrtc] home accepted
[webrtc] home accepted by android <id>
[webrtc] home rejected <id> (gestureRejected)
[webrtc] control command received: recents <id>
[webrtc] recents accepted
[webrtc] recents accepted by android <id>
[webrtc] recents rejected <id> (gestureRejected)
[webrtc] control command received: set_text <id>
[webrtc] set_text accepted
[webrtc] set_text accepted by android <id>
[webrtc] set_text rejected <id> (textTargetUnavailable)
[webrtc] set_text rejected <id> (textRejected)
[webrtc] control command received: ime_enter <id>
[webrtc] ime_enter accepted
[webrtc] ime_enter accepted by android <id>
[webrtc] ime_enter rejected <id> (textTargetUnavailable)
[webrtc] ime_enter rejected <id> (imeActionUnavailable)
[webrtc] ime_enter rejected <id> (imeActionRejected)
[webrtc] control message dropped: it belongs to a previous negotiation
```

`<name> accepted` is the session gate letting the command through, for every command.
`accepted by android` is what `back`, `home`, `recents`, `set_text` and `ime_enter` log where a
gesture logs `completed`, since that is all Android says about them.

and natively, under the logcat tag `RemoteControlInput`:

```text
accessibility service connected / disconnected
tap completed / cancelled / rejected / busy / invalid / unavailable
swipe completed / cancelled / rejected / busy / invalid / unavailable
back accepted / rejected / busy / unavailable
home accepted / rejected / busy / unavailable
recents accepted / rejected / busy / unavailable
set_text accepted / rejected / targetUnavailable / busy / invalid / unavailable
ime_enter accepted / rejected / targetUnavailable / actionUnavailable / busy / unavailable
```

Coordinates are not logged. Never: frames, SDP, ICE lines, tokens, secrets, the text
of a `set_text`, or anything read from a node: its value, hint, description, password,
or the label of any of its actions.
