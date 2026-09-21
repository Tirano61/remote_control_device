/// The screen's video track, as everything above the data layer may see it.
///
/// Deliberately opaque. A `MediaStreamTrack` is a handle into a native
/// libwebrtc object with a lifecycle of its own — stopping it stops the
/// capture, and holding one after it was stopped is how a native crash is
/// written — so the real thing never leaves `features/screen_capture/data`.
/// What travels instead is this: something that can be named in a log, carried
/// through a bloc, and handed back to the one adapter that knows what it
/// really is.
///
/// [id] is libwebrtc's own track UUID. It identifies a track within this
/// process and is neither a device identifier nor a credential, so it is safe
/// to compare and safe to print.
abstract interface class ScreenVideoTrack {
  String get id;
}
