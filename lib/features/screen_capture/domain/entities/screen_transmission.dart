import 'package:equatable/equatable.dart';

/// The heartbeat evidence an opening or a renewal of the screen's transmission
/// lease runs from.
///
/// [observedAtNanos] is an instant of Android's elapsed-realtime clock
/// (`CLOCK_BOOTTIME`), read when the evidence was observed. The native gate
/// lets frames through until `observedAtNanos + validFor` and not a nanosecond
/// longer, whenever the message carrying it arrives. [channel] names the
/// connection it was observed on: a lease is only ever renewed with evidence
/// of the connection it was opened with.
final class ScreenTransmissionEvidence extends Equatable {
  const ScreenTransmissionEvidence({
    required this.channel,
    required this.observedAtNanos,
    required this.validFor,
  });

  final int channel;
  final int observedAtNanos;
  final Duration validFor;

  @override
  List<Object?> get props => [channel, observedAtNanos, validFor];
}

/// What became of a transmission change.
enum ScreenTransmissionOutcome {
  /// Done: closed, or open with a lease that has time left. Also the answer
  /// when there is no capture to change.
  applied,

  /// Opened, but nothing goes through: the evidence it was given had already
  /// run out by the time it reached the gate, the gate refused it, or there
  /// was no evidence to give. The heartbeat has to be confirmed again.
  lapsed,

  /// The platform could not apply it, and the capture has been stopped.
  failed,
}

/// What became of a renewal of the running lease.
enum ScreenTransmissionRenewal {
  /// The lease runs from this evidence now, and frames go through.
  renewed,

  /// The lease had run out before this evidence, or this evidence already is
  /// too old, or it belongs to another connection: frames are held back, and
  /// nothing but a new opening — after the authority is confirmed again —
  /// sends them again.
  lapsed,

  /// Nothing to renew: no capture, the gate is closed, or the message is
  /// older than what the lease already has. Nothing to report either.
  ignored,
}

/// The native gate's answer to a renewal, before the client reads it.
enum ScreenLeaseRenewalResult { renewed, lapsed, ignored, rejected }

/// The native gate's answer to a renewal: what it did, and whether frames go
/// through after it.
final class ScreenLeaseRenewalAnswer extends Equatable {
  const ScreenLeaseRenewalAnswer(this.result, {required this.live});

  final ScreenLeaseRenewalResult result;
  final bool live;

  @override
  List<Object?> get props => [result, live];
}
