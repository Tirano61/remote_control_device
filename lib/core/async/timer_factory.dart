import 'dart:async';

/// Creates the one-shot timers a policy needs, so that the policy can be tested
/// against a clock the test moves by hand.
///
/// Production code uses [systemTimerFactory]. Nothing here measures time on its
/// own: a deadline is a [Timer] and nothing else, so a test that replaces the
/// factory controls every deadline in the class under test.
typedef TimerFactory =
    Timer Function(Duration duration, void Function() onFire);

/// The real thing.
Timer systemTimerFactory(Duration duration, void Function() onFire) =>
    Timer(duration, onFire);
