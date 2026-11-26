/// A synchronous answer to "is there recent evidence that the backend can
/// still reach this tablet over `/devices`?".
///
/// It exists for the one place that cannot wait for the answer to travel
/// through the blocs: a remote command about to run. The authority it guards
/// is suspended through the normal path (realtime state, coordinator,
/// `RemoteSessionBloc`) a few event-loop turns after the evidence goes stale;
/// a command that arrives inside those turns, or after the tablet woke up late
/// and before its timers ran, is checked against the clock instead.
///
/// It never grants anything. `true` is necessary for a command to run, never
/// sufficient: the session's authority must still be confirmed.
abstract interface class RealtimeLiveness {
  /// `false` when the evidence is too old, or there is no connection at all.
  ///
  /// May start the suspension that the age implies: a caller that found it
  /// stale does not have to report it anywhere.
  bool confirmFresh();
}
