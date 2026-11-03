import 'dart:convert';

import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_inbound_message.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_data_channel_message.dart';

/// The wire format of the `control` channel, documented in
/// `docs/webrtc/CONTROL_CHANNEL.md`.
///
/// The only place a JSON map exists: what leaves here is typed, or is nothing.
/// Everything arriving is untrusted input from the other end of a data channel,
/// so nothing is coerced — a value that is not exactly what the protocol says
/// is refused rather than clamped, parsed or guessed at, and no input can throw
/// out of [decode].
abstract final class RemoteControlChannelCodec {
  static const int protocolVersion = 1;

  static const String _tapType = 'tap';
  static const String _swipeType = 'swipe';
  static const String _backType = 'back';
  static const String _homeType = 'home';
  static const String _recentsType = 'recents';
  static const String _ackType = 'ack';

  /// Decodes a frame, or answers `null` when there is nothing to report.
  ///
  /// `null` covers everything with no id to answer to: a binary frame, broken
  /// JSON, a payload that is not an object, a missing or empty id. Answering
  /// those would mean inventing an id.
  ///
  /// With an id, the version is read before anything else, because a message in
  /// another version has no reason to look like version 1 and must not be
  /// interpreted as if it did.
  static RemoteControlInboundMessage? decode(WebRtcDataChannelMessage frame) {
    final text = frame.text;
    if (text == null) return null;

    final Object? payload;
    try {
      payload = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (payload is! Map<String, dynamic>) return null;

    final id = payload['id'];
    if (id is! String || id.isEmpty) return null;

    final version = payload['v'];
    if (version is! int) {
      return _rejected(id, RemoteControlError.invalidCommand);
    }
    if (version != protocolVersion) {
      return _rejected(id, RemoteControlError.unsupportedCommand);
    }

    final type = payload['type'];
    if (type is! String) {
      return _rejected(id, RemoteControlError.invalidCommand);
    }
    return switch (type) {
      _tapType => _decodeTap(id, payload),
      _swipeType => _decodeSwipe(id, payload),
      _backType => RemoteControlCommandReceived(RemoteBackCommand(id: id)),
      _homeType => RemoteControlCommandReceived(RemoteHomeCommand(id: id)),
      _recentsType => RemoteControlCommandReceived(
        RemoteRecentsCommand(id: id),
      ),
      _ => _rejected(id, RemoteControlError.unsupportedCommand),
    };
  }

  static RemoteControlInboundMessage _decodeTap(
    String id,
    Map<String, dynamic> payload,
  ) {
    final x = _normalized(payload['x']);
    final y = _normalized(payload['y']);
    if (x == null || y == null) {
      return _rejected(id, RemoteControlError.invalidCommand);
    }
    return RemoteControlCommandReceived(RemoteTapCommand(id: id, x: x, y: y));
  }

  /// A swipe that goes nowhere is refused rather than run as a tap: the sender
  /// has a command for that, and this one saying otherwise is a mistake on its
  /// side worth reporting.
  static RemoteControlInboundMessage _decodeSwipe(
    String id,
    Map<String, dynamic> payload,
  ) {
    final startX = _normalized(payload['startX']);
    final startY = _normalized(payload['startY']);
    final endX = _normalized(payload['endX']);
    final endY = _normalized(payload['endY']);
    final durationMs = _swipeDuration(payload['durationMs']);
    if (startX == null ||
        startY == null ||
        endX == null ||
        endY == null ||
        durationMs == null ||
        (startX == endX && startY == endY)) {
      return _rejected(id, RemoteControlError.invalidCommand);
    }
    return RemoteControlCommandReceived(
      RemoteSwipeCommand(
        id: id,
        startX: startX,
        startY: startY,
        endX: endX,
        endY: endY,
        durationMs: durationMs,
      ),
    );
  }

  static String encodeAck(RemoteControlAck ack) => jsonEncode(<String, Object>{
    'v': protocolVersion,
    'type': _ackType,
    'id': ack.id,
    'ok': ack.ok,
    if (ack.error case final error?) 'error': _wireError(error),
  });

  /// A number in `0..1`, or `null`. `1e999` parses to infinity, which is why
  /// being a number is not enough.
  static double? _normalized(Object? value) {
    if (value is! num || !value.isFinite) return null;
    if (value < 0 || value > 1) return null;
    return value.toDouble();
  }

  /// An integer in the allowed range, or `null`. `300.0` is a double once
  /// decoded, and is refused along with every other thing that is not an int.
  static int? _swipeDuration(Object? value) {
    if (value is! int) return null;
    if (value < RemoteSwipeCommand.minDurationMs ||
        value > RemoteSwipeCommand.maxDurationMs) {
      return null;
    }
    return value;
  }

  static RemoteControlInboundMessage _rejected(
    String id,
    RemoteControlError error,
  ) => RemoteControlMessageRejected(id, error);

  static String _wireError(RemoteControlError error) => switch (error) {
    RemoteControlError.accessibilityUnavailable => 'accessibility_unavailable',
    RemoteControlError.sessionNotActive => 'session_not_active',
    RemoteControlError.gestureRejected => 'gesture_rejected',
    RemoteControlError.invalidCommand => 'invalid_command',
    RemoteControlError.unsupportedCommand => 'unsupported_command',
  };
}
