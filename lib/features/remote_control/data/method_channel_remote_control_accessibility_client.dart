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
/// commands. It has to outlast the longest gesture, or a gesture still running
/// would be reported as refused: the longest swipe the protocol allows, and a
/// long press, whose length the Android side takes from the device's
/// long-press timeout plus a margin and caps well below this guard. Dart never
/// learns that length, so the one guard covers both rather than each gesture
/// estimating its own.
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
  static const String longPressMethod = 'performLongPress';
  static const String swipeMethod = 'performSwipe';
  static const String backMethod = 'performBack';
  static const String homeMethod = 'performHome';
  static const String recentsMethod = 'performRecents';
  static const String setTextMethod = 'performSetText';
  static const String imeEnterMethod = 'performImeEnter';
  static const String settingsMethod = 'openAccessibilitySettings';
  static const String availabilityChangedMethod =
      'accessibilityServiceAvailabilityChanged';
  static const String startTouchMethod = 'startRemoteTouch';
  static const String moveTouchMethod = 'moveRemoteTouch';
  static const String releaseTouchMethod = 'releaseRemoteTouch';
  static const String cancelTouchMethod = 'cancelRemoteTouch';
  static const String abandonTouchMethod = 'abandonRemoteTouch';
  static const String touchEndedMethod = 'remoteTouchEnded';
  static const String openControlMethod = 'openRemoteControl';
  static const String closeControlMethod = 'closeRemoteControl';

  /// What every command carries when no grant is open: never a grant the
  /// Android side has opened, since grants start at 1.
  static const int noGrant = 0;

  final Duration gestureTimeout;

  /// The grant [openControl] opened last, until [closeControl]. Stamped on
  /// every command at the moment it is sent, which is the moment it is put on
  /// the channel: the Android side receives calls in the order they are made.
  int? _grant;

  int get _grantForCall => _grant ?? noGrant;

  /// The handler goes on when someone listens rather than at construction,
  /// which happens before the Flutter binding exists, and comes off when
  /// nobody listens to either stream.
  late final StreamController<RemoteControlAccessibilityStatus> _statusChanges =
      StreamController<RemoteControlAccessibilityStatus>.broadcast(
        onListen: _listen,
        onCancel: _unlisten,
      );

  late final StreamController<int> _touchEnds = StreamController<int>.broadcast(
    onListen: _listen,
    onCancel: _unlisten,
  );

  int _listening = 0;

  void _listen() {
    if (_listening++ == 0) channel.setMethodCallHandler(_onNativeCall);
  }

  void _unlisten() {
    if (--_listening == 0) channel.setMethodCallHandler(null);
  }

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

  /// Only the position crosses the bridge: there is no duration to send.
  @override
  Future<RemoteGestureOutcome> longPress(
    double normalizedX,
    double normalizedY,
  ) => _perform(longPressMethod, <String, Object>{
    'x': normalizedX,
    'y': normalizedY,
  });

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

  /// A `busy` from the Android side is a refusal like any other, and goes no
  /// further than this.
  @override
  Future<RemoteTextOutcome> performSetText(String text) async {
    try {
      final outcome = await channel
          .invokeMethod<String>(setTextMethod, <String, Object>{
            'text': text,
            'grant': _grantForCall,
          })
          .timeout(gestureTimeout);
      return switch (outcome) {
        'completed' => RemoteTextOutcome.completed,
        'targetUnavailable' => RemoteTextOutcome.targetUnavailable,
        'unavailable' => RemoteTextOutcome.unavailable,
        'revoked' => RemoteTextOutcome.revoked,
        _ => RemoteTextOutcome.rejected,
      };
    } on MissingPluginException {
      return RemoteTextOutcome.unavailable;
    } catch (_) {
      return RemoteTextOutcome.rejected;
    }
  }

  /// No arguments cross the bridge, and only an outcome comes back. A `busy`
  /// from the Android side is a refusal, as for [performSetText].
  @override
  Future<RemoteImeEnterOutcome> performImeEnter() async {
    try {
      final outcome = await channel
          .invokeMethod<String>(imeEnterMethod, <String, Object>{
            'grant': _grantForCall,
          })
          .timeout(gestureTimeout);
      return switch (outcome) {
        'completed' => RemoteImeEnterOutcome.completed,
        'targetUnavailable' => RemoteImeEnterOutcome.targetUnavailable,
        'actionUnavailable' => RemoteImeEnterOutcome.actionUnavailable,
        'unavailable' => RemoteImeEnterOutcome.unavailable,
        'revoked' => RemoteImeEnterOutcome.revoked,
        _ => RemoteImeEnterOutcome.rejected,
      };
    } on MissingPluginException {
      return RemoteImeEnterOutcome.unavailable;
    } catch (_) {
      return RemoteImeEnterOutcome.rejected;
    }
  }

  Future<RemoteGestureOutcome> _perform(
    String method, [
    Map<String, Object>? arguments,
  ]) async {
    try {
      final outcome = await channel
          .invokeMethod<String>(method, <String, Object>{
            ...?arguments,
            'grant': _grantForCall,
          })
          .timeout(gestureTimeout);
      return switch (outcome) {
        'completed' => RemoteGestureOutcome.completed,
        'unavailable' => RemoteGestureOutcome.unavailable,
        'revoked' => RemoteGestureOutcome.revoked,
        _ => RemoteGestureOutcome.rejected,
      };
    } on MissingPluginException {
      return RemoteGestureOutcome.unavailable;
    } catch (_) {
      return RemoteGestureOutcome.rejected;
    }
  }

  /// Answered once the hold is over, which the Android side caps as it caps a
  /// long press, so [gestureTimeout] covers it. No answer in time is a refusal,
  /// and the caller abandons the touch.
  @override
  Future<RemoteTouchStartOutcome> startTouch({
    required int touch,
    required double x,
    required double y,
  }) async {
    try {
      final outcome = await channel
          .invokeMethod<String>(startTouchMethod, <String, Object>{
            'touch': touch,
            'x': x,
            'y': y,
            'grant': _grantForCall,
          })
          .timeout(gestureTimeout);
      return switch (outcome) {
        'held' => RemoteTouchStartOutcome.held,
        'ended' => RemoteTouchStartOutcome.ended,
        'unsupported' => RemoteTouchStartOutcome.unsupported,
        'unavailable' => RemoteTouchStartOutcome.unavailable,
        'revoked' => RemoteTouchStartOutcome.revoked,
        _ => RemoteTouchStartOutcome.rejected,
      };
    } on MissingPluginException {
      return RemoteTouchStartOutcome.unavailable;
    } catch (_) {
      return RemoteTouchStartOutcome.rejected;
    }
  }

  /// Answered at once on the Android side. Anything but `accepted` or
  /// `unavailable`, no answer included, means the touch cannot go on.
  @override
  Future<RemoteTouchMoveOutcome> moveTouch({
    required int touch,
    required int seq,
    required double x,
    required double y,
  }) async {
    try {
      final outcome = await channel
          .invokeMethod<String>(moveTouchMethod, <String, Object>{
            'touch': touch,
            'seq': seq,
            'x': x,
            'y': y,
            'grant': _grantForCall,
          })
          .timeout(gestureTimeout);
      return switch (outcome) {
        'accepted' => RemoteTouchMoveOutcome.accepted,
        'unavailable' => RemoteTouchMoveOutcome.unavailable,
        _ => RemoteTouchMoveOutcome.ended,
      };
    } on MissingPluginException {
      return RemoteTouchMoveOutcome.unavailable;
    } catch (_) {
      return RemoteTouchMoveOutcome.ended;
    }
  }

  @override
  Future<RemoteTouchReleaseOutcome> releaseTouch({
    required int touch,
    required int seq,
    required double x,
    required double y,
  }) async {
    try {
      final outcome = await channel
          .invokeMethod<String>(releaseTouchMethod, <String, Object>{
            'touch': touch,
            'seq': seq,
            'x': x,
            'y': y,
            'grant': _grantForCall,
          })
          .timeout(gestureTimeout);
      return switch (outcome) {
        'completed' => RemoteTouchReleaseOutcome.completed,
        'unavailable' => RemoteTouchReleaseOutcome.unavailable,
        _ => RemoteTouchReleaseOutcome.ended,
      };
    } on MissingPluginException {
      return RemoteTouchReleaseOutcome.unavailable;
    } catch (_) {
      return RemoteTouchReleaseOutcome.ended;
    }
  }

  /// Whatever the answer, the touch is over as far as Dart is concerned.
  @override
  Future<void> cancelTouch({required int touch, required int seq}) async {
    try {
      await channel
          .invokeMethod<String>(cancelTouchMethod, <String, Object>{
            'touch': touch,
            'seq': seq,
          })
          .timeout(gestureTimeout);
    } catch (_) {
      // Gone, or unanswered: either way there is nothing left to wait for.
    }
  }

  @override
  void abandonTouch({required int touch}) {
    unawaited(
      channel
          .invokeMethod<void>(abandonTouchMethod, <String, Object>{
            'touch': touch,
          })
          .catchError((Object _) {
            // No service means no touch: nothing was left down.
          }),
    );
  }

  @override
  Stream<int> get touchEnds => _touchEnds.stream;

  @override
  Future<RemoteControlOpenOutcome> openControl({
    required int grant,
    required String remoteSessionId,
  }) async {
    // Before the call: whatever is sent after this line is sent under it, and
    // reaches the Android side after the opening does.
    _grant = grant;
    try {
      final outcome = await channel
          .invokeMethod<String>(openControlMethod, <String, Object>{
            'grant': grant,
            'session': remoteSessionId,
          })
          .timeout(gestureTimeout);
      return switch (outcome) {
        'opened' => RemoteControlOpenOutcome.opened,
        'ended' => RemoteControlOpenOutcome.ended,
        _ => RemoteControlOpenOutcome.stale,
      };
    } catch (_) {
      return RemoteControlOpenOutcome.unavailable;
    }
  }

  @override
  void closeControl({String? endedRemoteSessionId}) {
    // Before the call, and not waited on: nothing sent from here on carries an
    // open grant, whatever the Android side answers or whether it answers.
    _grant = null;
    unawaited(
      channel
          .invokeMethod<void>(closeControlMethod, <String, Object>{
            'ended': ?endedRemoteSessionId,
          })
          .catchError((Object _) {
            // No Android side means nothing is running there to stop.
          }),
    );
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
    switch (call.method) {
      case availabilityChangedMethod:
        final available = call.arguments;
        if (available is bool) _statusChanges.add(_statusOf(available));
      case touchEndedMethod:
        final touch = call.arguments;
        if (touch is int) _touchEnds.add(touch);
    }
  }

  static RemoteControlAccessibilityStatus _statusOf(bool available) => available
      ? RemoteControlAccessibilityStatus.available
      : RemoteControlAccessibilityStatus.unavailable;
}
