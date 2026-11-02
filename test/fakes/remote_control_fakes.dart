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

  /// What every tap answers, unless [holdGestures] is set.
  RemoteGestureOutcome outcome = RemoteGestureOutcome.completed;

  /// When true, a tap does not answer until the test calls [finishGesture]. The
  /// only way to observe what arrives while a gesture is running.
  bool holdGestures = false;

  /// Every tap that actually reached the service, as `(x, y)`. Its being empty
  /// is what "no gesture" means in these tests.
  final List<(double, double)> taps = [];

  int settingsOpened = 0;

  final List<Completer<RemoteGestureOutcome>> _heldGestures = [];
  final StreamController<RemoteControlAccessibilityStatus> _statusChanges =
      StreamController<RemoteControlAccessibilityStatus>.broadcast();

  /// Answers the oldest tap still running.
  void finishGesture([RemoteGestureOutcome result = RemoteGestureOutcome.completed]) =>
      _heldGestures.removeAt(0).complete(result);

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
    taps.add((normalizedX, normalizedY));
    if (!holdGestures) return Future.value(outcome);
    final held = Completer<RemoteGestureOutcome>();
    _heldGestures.add(held);
    return held.future;
  }

  @override
  Future<void> openAccessibilitySettings() async => settingsOpened++;
}
