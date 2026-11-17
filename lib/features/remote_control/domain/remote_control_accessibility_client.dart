/// Whether Android's accessibility service is connected.
///
/// `available` is a fact about the system and authorises nothing. The service
/// stays connected between assistances, and only an `ACTIVE` remote session
/// lets a command through to it.
enum RemoteControlAccessibilityStatus { available, unavailable }

/// What became of a gesture, or of a Back, a Home or a Recents.
enum RemoteGestureOutcome {
  /// Android reported the gesture completed. For a Back, a Home or a Recents it
  /// reported taking the action: it has no way of saying when that action ends.
  completed,

  /// Android cancelled or refused it.
  rejected,

  /// The accessibility service is not connected.
  unavailable,
}

/// What became of a `set_text`. Its own type because it fails differently from
/// a gesture: a valid one may simply have no field to write to.
enum RemoteTextOutcome {
  /// The focused field took the action. Nothing reads the field back, so this
  /// does not say what it ended up holding.
  completed,

  /// No active window, nothing with input focus, or a focused node that is not
  /// editable and enabled.
  targetUnavailable,

  /// There was somewhere to write, and the text could not be put there.
  rejected,

  /// The accessibility service is not connected.
  unavailable,
}

/// What became of an `ime_enter`. Its own type because, besides having no
/// field to act on, a valid one may find a field with no IME action.
enum RemoteImeEnterOutcome {
  /// The focused field took `ACTION_IME_ENTER`. That Android took it is all
  /// this says: not what the application then did with it.
  completed,

  /// No active window, nothing with input focus, or a focused node that is not
  /// editable and enabled.
  targetUnavailable,

  /// The focused field is a valid target and does not list `ACTION_IME_ENTER`.
  actionUnavailable,

  /// The field lists the action and it was not taken, or a gesture was still
  /// running.
  rejected,

  /// The accessibility service is not connected.
  unavailable,
}

/// What became of the hold that starts a remote touch.
enum RemoteTouchStartOutcome {
  /// The finger is down, has been down longer than this device's long-press
  /// timeout, and the touch goes on.
  held,

  /// The touch ended before the hold was over: cancelled, abandoned, or
  /// cancelled by Android.
  ended,

  /// It could not start: Android refused the stroke, something else is running,
  /// or something it needed could not be read.
  rejected,

  /// Continued strokes do not exist on this Android version (below 8.0).
  unsupported,

  /// The accessibility service is not connected.
  unavailable,
}

/// What became of one move of a remote touch.
enum RemoteTouchMoveOutcome {
  /// The position was taken. Not that the finger is there yet.
  accepted,

  /// The touch cannot go on, or is not there.
  ended,

  /// The accessibility service is not connected.
  unavailable,
}

/// What became of the release of a remote touch.
enum RemoteTouchReleaseOutcome {
  /// The final stroke completed: Android received the end of the contact.
  completed,

  /// The touch cannot go on, or is not there, and was not released.
  ended,

  /// The accessibility service is not connected.
  unavailable,
}

/// The boundary `AccessibilityService` lives behind.
///
/// Nothing here can enable the service, because nothing can: Android requires
/// the user to do it in its own settings, and [openAccessibilitySettings] only
/// takes them there.
abstract interface class RemoteControlAccessibilityClient {
  /// Every change of the service's status, starting with the next one.
  Stream<RemoteControlAccessibilityStatus> get statusChanges;

  /// Never throws: a service that cannot be asked is an unavailable one.
  Future<RemoteControlAccessibilityStatus> currentStatus();

  /// Touches the screen at a position normalized over the whole screen, and
  /// completes when Android says what became of it.
  ///
  /// Never throws. Authorising the tap is the caller's job: this runs whatever
  /// it is given, which is why only `RemoteControlCommandQueue` calls it.
  Future<RemoteGestureOutcome> tap(double normalizedX, double normalizedY);

  /// Holds a touch at a position normalized as for [tap], for as long as this
  /// device takes to read it as a long press, and completes when Android says
  /// what became of it. How long that is is decided on the Android side.
  ///
  /// Never throws. Like [tap], it runs whatever it is given.
  Future<RemoteGestureOutcome> longPress(
    double normalizedX,
    double normalizedY,
  );

  /// Draws one straight stroke between two normalized positions, taking
  /// [durationMs], and completes when Android says what became of it.
  ///
  /// Never throws. Like [tap], it runs whatever it is given.
  Future<RemoteGestureOutcome> swipe({
    required double startX,
    required double startY,
    required double endX,
    required double endY,
    required int durationMs,
  });

  /// Android's Back, and completes when Android says whether it took it.
  ///
  /// Never throws. Like [tap], it runs whatever it is given.
  Future<RemoteGestureOutcome> performBack();

  /// Android's Home, and completes when Android says whether it took it.
  ///
  /// Never throws. Like [tap], it runs whatever it is given.
  Future<RemoteGestureOutcome> performHome();

  /// Android's Recents, and completes when Android says whether it took it.
  ///
  /// Never throws. Like [tap], it runs whatever it is given.
  Future<RemoteGestureOutcome> performRecents();

  /// Replaces the content of the field with input focus with [text], and
  /// completes when Android says whether it took it. Nothing about the field
  /// comes back.
  ///
  /// Never throws. Like [tap], it runs whatever it is given, and this is the
  /// only reason the Android side looks at the active window at all.
  Future<RemoteTextOutcome> performSetText(String text);

  /// Runs the IME action of the field with input focus, and completes when
  /// Android says whether it took it. Nothing about the field comes back.
  ///
  /// Never throws. Like [tap], it runs whatever it is given, and like
  /// [performSetText] it is a reason the Android side looks at the active
  /// window.
  Future<RemoteImeEnterOutcome> performImeEnter();

  /// Puts a finger down at a normalized position and keeps it down, and
  /// completes once the hold is over or the touch could not get that far.
  ///
  /// [touch] is a handle the caller chooses, and the only name the Android side
  /// knows the touch by. Never throws. Like [tap], it runs whatever it is given.
  Future<RemoteTouchStartOutcome> startTouch({
    required int touch,
    required double x,
    required double y,
  });

  /// Gives the finger of [touch] a new position, and completes as soon as the
  /// Android side has taken it or refused it, not when the finger is there.
  ///
  /// Never throws. Like [tap], it runs whatever it is given.
  Future<RemoteTouchMoveOutcome> moveTouch({
    required int touch,
    required int seq,
    required double x,
    required double y,
  });

  /// Lifts the finger of [touch] at a position, and completes when Android
  /// says what became of the final stroke.
  ///
  /// Never throws. Like [tap], it runs whatever it is given.
  Future<RemoteTouchReleaseOutcome> releaseTouch({
    required int touch,
    required int seq,
    required double x,
    required double y,
  });

  /// Takes the finger of [touch] away without a release, and completes when it
  /// is gone, or there was none. Never throws.
  Future<void> cancelTouch({required int touch, required int seq});

  /// Ends [touch] on the Android side without waiting for anything: the
  /// session, the channel or the peer connection it belonged to is gone.
  ///
  /// Never throws, and there is nothing to wait for.
  void abandonTouch({required int touch});

  /// The handle of every touch that ended on the Android side on its own: its
  /// watchdog, its lifetime, the display changing, Android cancelling it.
  Stream<int> get touchEnds;

  /// Opens Android's accessibility settings. Never throws.
  Future<void> openAccessibilitySettings();
}
