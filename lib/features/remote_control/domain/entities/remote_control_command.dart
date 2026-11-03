import 'package:equatable/equatable.dart';

/// Something the technician asked this device to do, already validated.
///
/// Reaching this type says the *message* was well formed and nothing else.
/// Whether it may be executed is a separate question, asked again by
/// `WebRtcSessionBloc` against the remote session the user authorised.
sealed class RemoteControlCommand extends Equatable {
  const RemoteControlCommand(this.id);

  /// Chosen by the sender and opaque here: it is echoed in the ack and never
  /// interpreted, so nothing assumes it is a UUID.
  final String id;

  @override
  List<Object?> get props => [id];
}

/// One short touch on the screen.
///
/// [x] and [y] are in `0.0..1.0` over the *whole remote frame*, origin top-left,
/// `x` growing right and `y` growing down. They are not CSS pixels and not
/// device pixels: which pixel they name depends on how the screen is turned at
/// the moment the gesture runs, and only the Android side knows that.
final class RemoteTapCommand extends RemoteControlCommand {
  const RemoteTapCommand({required String id, required this.x, required this.y})
    : super(id);

  final double x;
  final double y;

  @override
  List<Object?> get props => [id, x, y];
}

/// One straight stroke across the screen, from a start to a different end.
///
/// The four positions are normalized exactly as in [RemoteTapCommand], and for
/// the same reason. [durationMs] is how long the finger takes, which is what
/// separates a fling from a slow drag, so it is never defaulted.
final class RemoteSwipeCommand extends RemoteControlCommand {
  const RemoteSwipeCommand({
    required String id,
    required this.startX,
    required this.startY,
    required this.endX,
    required this.endY,
    required this.durationMs,
  }) : super(id);

  static const int minDurationMs = 50;
  static const int maxDurationMs = 2000;

  final double startX;
  final double startY;
  final double endX;
  final double endY;
  final int durationMs;

  @override
  List<Object?> get props => [id, startX, startY, endX, endY, durationMs];
}

/// Android's Back. It names no position and depends on no screen, so it is not
/// a touch: an [id] is all there is to it.
final class RemoteBackCommand extends RemoteControlCommand {
  const RemoteBackCommand({required String id}) : super(id);
}

/// Android's Home. Like [RemoteBackCommand], an [id] and nothing else.
final class RemoteHomeCommand extends RemoteControlCommand {
  const RemoteHomeCommand({required String id}) : super(id);
}

/// Android's Recents. Like [RemoteBackCommand], an [id] and nothing else.
final class RemoteRecentsCommand extends RemoteControlCommand {
  const RemoteRecentsCommand({required String id}) : super(id);
}

/// Replaces the whole content of the field that has input focus with [text].
///
/// It is not a key press and not an insertion at the cursor, and an empty [text]
/// empties the field. It names no field: which one it reaches is whichever has
/// input focus when it runs, which is why a tap usually comes first.
///
/// [text] is whatever the technician typed, which may be a password. It stays
/// out of [toString], which `Equatable` would otherwise fill with it in debug
/// builds.
final class RemoteSetTextCommand extends RemoteControlCommand {
  const RemoteSetTextCommand({required String id, required this.text})
    : super(id);

  /// In UTF-16 code units, which is what `String.length` counts in both Dart
  /// and Kotlin, so the two sides cannot disagree about a limit case.
  static const int maxRemoteTextLength = 4096;

  final String text;

  @override
  List<Object?> get props => [id, text];

  @override
  String toString() => 'RemoteSetTextCommand($id)';
}
