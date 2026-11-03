import 'dart:async';

import 'package:flutter/services.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';

/// The Flutter side of the bridge to `RemoteControlAccessibilityChannel.kt`.
///
/// No state and no policy. Whether the service is connected is known on the
/// Android side, and whether a gesture may run is decided above this class.
///
/// The Android side always answers a gesture, including when the service goes
/// away mid-gesture, so [gestureTimeout] is a guard against a bridge that never
/// answers: a queue waiting on a lost reply would otherwise stop running
/// commands. It has to outlast the longest swipe the protocol allows, or a
/// gesture still running would be reported as refused.
class MethodChannelRemoteControlAccessibilityClient
    implements RemoteControlAccessibilityClient {
  MethodChannelRemoteControlAccessibilityClient({
    this.gestureTimeout = const Duration(seconds: 5),
  });

  static const MethodChannel channel = MethodChannel(
    'remote_control/accessibility',
  );

  static const String availableMethod = 'isAccessibilityServiceAvailable';
  static const String tapMethod = 'performTap';
  static const String swipeMethod = 'performSwipe';
  static const String backMethod = 'performBack';
  static const String homeMethod = 'performHome';
  static const String recentsMethod = 'performRecents';
  static const String settingsMethod = 'openAccessibilitySettings';
  static const String availabilityChangedMethod =
      'accessibilityServiceAvailabilityChanged';

  final Duration gestureTimeout;

  /// The handler goes on when someone listens rather than at construction,
  /// which happens before the Flutter binding exists.
  late final StreamController<RemoteControlAccessibilityStatus> _statusChanges =
      StreamController<RemoteControlAccessibilityStatus>.broadcast(
        onListen: () => channel.setMethodCallHandler(_onNativeCall),
        onCancel: () => channel.setMethodCallHandler(null),
      );

  @override
  Stream<RemoteControlAccessibilityStatus> get statusChanges =>
      _statusChanges.stream;

  @override
  Future<RemoteControlAccessibilityStatus> currentStatus() async {
    try {
      final available = await channel.invokeMethod<bool>(availableMethod);
      return _statusOf(available ?? false);
    } catch (_) {
      return RemoteControlAccessibilityStatus.unavailable;
    }
  }

  @override
  Future<RemoteGestureOutcome> tap(double normalizedX, double normalizedY) =>
      _perform(tapMethod, <String, Object>{'x': normalizedX, 'y': normalizedY});

  @override
  Future<RemoteGestureOutcome> swipe({
    required double startX,
    required double startY,
    required double endX,
    required double endY,
    required int durationMs,
  }) => _perform(swipeMethod, <String, Object>{
    'startX': startX,
    'startY': startY,
    'endX': endX,
    'endY': endY,
    'durationMs': durationMs,
  });

  @override
  Future<RemoteGestureOutcome> performBack() => _perform(backMethod);

  @override
  Future<RemoteGestureOutcome> performHome() => _perform(homeMethod);

  @override
  Future<RemoteGestureOutcome> performRecents() => _perform(recentsMethod);

  Future<RemoteGestureOutcome> _perform(
    String method, [
    Map<String, Object>? arguments,
  ]) async {
    try {
      final outcome = await channel
          .invokeMethod<String>(method, arguments)
          .timeout(gestureTimeout);
      return switch (outcome) {
        'completed' => RemoteGestureOutcome.completed,
        'unavailable' => RemoteGestureOutcome.unavailable,
        _ => RemoteGestureOutcome.rejected,
      };
    } on MissingPluginException {
      return RemoteGestureOutcome.unavailable;
    } catch (_) {
      return RemoteGestureOutcome.rejected;
    }
  }

  @override
  Future<void> openAccessibilitySettings() async {
    try {
      await channel.invokeMethod<void>(settingsMethod);
    } catch (_) {
      // Nothing the user can be told that the unchanged status does not say.
    }
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method != availabilityChangedMethod) return;
    final available = call.arguments;
    if (available is bool) _statusChanges.add(_statusOf(available));
  }

  static RemoteControlAccessibilityStatus _statusOf(bool available) => available
      ? RemoteControlAccessibilityStatus.available
      : RemoteControlAccessibilityStatus.unavailable;
}
