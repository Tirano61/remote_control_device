/// Why a command was not carried out.
///
/// A closed set, because the web decides what to do from it and a stack trace
/// or a platform message must never reach the other end of the channel.
enum RemoteControlError {
  /// The Android accessibility service is not connected.
  accessibilityUnavailable,

  /// There is no `ACTIVE` remote session for this peer connection.
  sessionNotActive,

  /// The gesture was refused, cancelled, or could not be attempted. Android
  /// refusing a Back, a Home or a Recents is this too: the name is older than
  /// those commands, and it is on the wire, so it stays.
  gestureRejected,

  /// The message was malformed.
  invalidCommand,

  /// The message was well formed, in a version or of a type this build does not
  /// know.
  unsupportedCommand,

  /// The `set_text` was valid and had nowhere to go: no active window, nothing
  /// with input focus, or a focused node that is not editable and enabled.
  textTargetUnavailable,

  /// There was somewhere to write, and the text could not be put there.
  textRejected,
}
