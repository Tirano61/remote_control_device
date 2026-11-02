/// Whether Android's accessibility service is connected.
///
/// `available` is a fact about the system and authorises nothing. The service
/// stays connected between assistances, and only an `ACTIVE` remote session
/// lets a command through to it.
enum RemoteControlAccessibilityStatus { available, unavailable }

/// What became of a tap.
enum RemoteTapOutcome {
  /// Android reported the gesture completed.
  completed,

  /// Android cancelled or refused it.
  rejected,

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
  Future<RemoteTapOutcome> tap(double normalizedX, double normalizedY);

  /// Opens Android's accessibility settings. Never throws.
  Future<void> openAccessibilitySettings();
}
