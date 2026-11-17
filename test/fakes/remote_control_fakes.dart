import 'dart:async';

import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';

/// A stand-in for Android's accessibility service. A unit test cannot run
/// `dispatchGesture`; everything that decides whether it would be called is
/// ordinary Dart and is tested against this. What happens on the Android side
/// has its own JVM tests.
class FakeRemoteControlAccessibilityClient
    implements RemoteControlAccessibilityClient {
  RemoteControlAccessibilityStatus status =
      RemoteControlAccessibilityStatus.available;

  /// What every gesture answers, unless [holdGestures] is set.
  RemoteGestureOutcome outcome = RemoteGestureOutcome.completed;

  /// When true, a gesture does not answer until the test calls [finishGesture].
  /// The only way to observe what arrives while a gesture is running.
  bool holdGestures = false;

  /// Every tap that actually reached the service, as `(x, y)`. Its being empty
  /// is what "no gesture" means in these tests.
  final List<(double, double)> taps = [];

  /// Every long press that actually reached the service, as `(x, y)`.
  final List<(double, double)> longPresses = [];

  /// Every swipe that actually reached the service, as
  /// `(startX, startY, endX, endY, durationMs)`.
  final List<(double, double, double, double, int)> swipes = [];

  /// Every Back, Home and Recents that actually reached the service, as
  /// `'back'`, `'home'` or `'recents'`. Its being empty is what "no global
  /// action" means in these tests.
  final List<String> globalActions = [];

  /// What every `set_text` answers once it is let through.
  RemoteTextOutcome textOutcome = RemoteTextOutcome.completed;

  /// Every text that actually reached the service. Its being empty is what "the
  /// active window was not consulted" means on this side of the bridge: looking
  /// at the window happens behind this call and nowhere else.
  final List<String> setTexts = [];

  /// What every `ime_enter` answers once it is let through.
  RemoteImeEnterOutcome imeEnterOutcome = RemoteImeEnterOutcome.completed;

  /// How many `ime_enter` actually reached the service. Like [setTexts], its
  /// being zero is what "the active window was not consulted" means here.
  int imeEnters = 0;

  /// [taps], [longPresses], [swipes], [globalActions], [setTexts] and
  /// [imeEnters] together, in the order they reached the service. A long press
  /// appears as `('long_press', x, y)`, so it cannot be taken for a tap, a text
  /// as `('set_text', text)`, an IME action as `'ime_enter'`.
  final List<Object> gestures = [];

  int settingsOpened = 0;

  /// Every remote touch call that reached the service, in order:
  /// `('start', touch, x, y)`, `('move', touch, seq, x, y)`,
  /// `('release', touch, seq, x, y)`, `('cancel', touch, seq)` and
  /// `('abandon', touch)`. A start also appears in [gestures] as
  /// `('touch_hold', x, y)`, so it is ordered among the other commands.
  final List<Object> touchCalls = [];

  /// What every move answers.
  RemoteTouchMoveOutcome touchMoveOutcome = RemoteTouchMoveOutcome.accepted;

  /// What every start answers at once, or `null` to wait for [answerStart].
  RemoteTouchStartOutcome? touchStartOutcome;

  final List<Completer<RemoteTouchStartOutcome>> _touchStarts = [];
  final List<Completer<RemoteTouchReleaseOutcome>> _touchReleases = [];
  final List<Completer<void>> _touchCancels = [];
  final StreamController<int> _touchEnds = StreamController<int>.broadcast();

  /// The oldest start still waiting gets [outcome]: the hold is over.
  void answerStart([
    RemoteTouchStartOutcome outcome = RemoteTouchStartOutcome.held,
  ]) => _touchStarts.removeAt(0).complete(outcome);

  /// The oldest release still waiting gets [outcome].
  void answerRelease([
    RemoteTouchReleaseOutcome outcome = RemoteTouchReleaseOutcome.completed,
  ]) => _touchReleases.removeAt(0).complete(outcome);

  /// The oldest cancel still waiting is over.
  void answerCancel() => _touchCancels.removeAt(0).complete();

  int get pendingTouchStarts => _touchStarts.length;
  int get pendingTouchReleases => _touchReleases.length;
  int get pendingTouchCancels => _touchCancels.length;

  /// What the Android side says when a touch ends on its own.
  void pushTouchEnded(int touch) => _touchEnds.add(touch);

  final List<Completer<RemoteGestureOutcome>> _heldGestures = [];
  final StreamController<RemoteControlAccessibilityStatus> _statusChanges =
      StreamController<RemoteControlAccessibilityStatus>.broadcast();

  /// Answers the oldest gesture still running.
  void finishGesture([
    RemoteGestureOutcome result = RemoteGestureOutcome.completed,
  ]) => _heldGestures.removeAt(0).complete(result);

  /// What Android would report when the user enables or disables the service.
  void pushStatus(RemoteControlAccessibilityStatus next) {
    status = next;
    _statusChanges.add(next);
  }

  @override
  Stream<RemoteControlAccessibilityStatus> get statusChanges =>
      _statusChanges.stream;

  @override
  Future<RemoteControlAccessibilityStatus> currentStatus() async => status;

  @override
  Future<RemoteGestureOutcome> tap(double normalizedX, double normalizedY) {
    final tap = (normalizedX, normalizedY);
    taps.add(tap);
    gestures.add(tap);
    return _answer();
  }

  @override
  Future<RemoteGestureOutcome> longPress(
    double normalizedX,
    double normalizedY,
  ) {
    longPresses.add((normalizedX, normalizedY));
    gestures.add(('long_press', normalizedX, normalizedY));
    return _answer();
  }

  @override
  Future<RemoteGestureOutcome> swipe({
    required double startX,
    required double startY,
    required double endX,
    required double endY,
    required int durationMs,
  }) {
    final swipe = (startX, startY, endX, endY, durationMs);
    swipes.add(swipe);
    gestures.add(swipe);
    return _answer();
  }

  @override
  Future<RemoteGestureOutcome> performBack() => _globalAction('back');

  @override
  Future<RemoteGestureOutcome> performHome() => _globalAction('home');

  @override
  Future<RemoteGestureOutcome> performRecents() => _globalAction('recents');

  @override
  Future<RemoteTextOutcome> performSetText(String text) async {
    setTexts.add(text);
    gestures.add(('set_text', text));
    if (holdGestures) await _answer();
    return textOutcome;
  }

  @override
  Future<RemoteImeEnterOutcome> performImeEnter() async {
    imeEnters++;
    gestures.add('ime_enter');
    if (holdGestures) await _answer();
    return imeEnterOutcome;
  }

  @override
  Future<RemoteTouchStartOutcome> startTouch({
    required int touch,
    required double x,
    required double y,
  }) {
    touchCalls.add(('start', touch, x, y));
    gestures.add(('touch_hold', x, y));
    final immediate = touchStartOutcome;
    if (immediate != null) return Future.value(immediate);
    final started = Completer<RemoteTouchStartOutcome>();
    _touchStarts.add(started);
    return started.future;
  }

  @override
  Future<RemoteTouchMoveOutcome> moveTouch({
    required int touch,
    required int seq,
    required double x,
    required double y,
  }) async {
    touchCalls.add(('move', touch, seq, x, y));
    return touchMoveOutcome;
  }

  @override
  Future<RemoteTouchReleaseOutcome> releaseTouch({
    required int touch,
    required int seq,
    required double x,
    required double y,
  }) {
    touchCalls.add(('release', touch, seq, x, y));
    final released = Completer<RemoteTouchReleaseOutcome>();
    _touchReleases.add(released);
    return released.future;
  }

  @override
  Future<void> cancelTouch({required int touch, required int seq}) {
    touchCalls.add(('cancel', touch, seq));
    final cancelled = Completer<void>();
    _touchCancels.add(cancelled);
    return cancelled.future;
  }

  @override
  void abandonTouch({required int touch}) => touchCalls.add(('abandon', touch));

  @override
  Stream<int> get touchEnds => _touchEnds.stream;

  @override
  Future<void> openAccessibilitySettings() async => settingsOpened++;

  Future<RemoteGestureOutcome> _globalAction(String name) {
    globalActions.add(name);
    gestures.add(name);
    return _answer();
  }

  Future<RemoteGestureOutcome> _answer() {
    if (!holdGestures) return Future.value(outcome);
    final held = Completer<RemoteGestureOutcome>();
    _heldGestures.add(held);
    return held.future;
  }
}
