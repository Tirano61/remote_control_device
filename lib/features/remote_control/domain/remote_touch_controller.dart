import 'dart:async';

import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';

/// Where an ack goes. Whoever provides it decides whether it can still be sent.
typedef RemoteControlAckSink = void Function(RemoteControlAck ack);

/// What a remote touch belongs to: the assistance, the peer connection's
/// generation and the `control` channel it arrived on.
///
/// A message is about the running touch only if it comes with the same three.
/// The sender's `touch` name is not enough: a new connection may reuse it.
class RemoteTouchBinding {
  const RemoteTouchBinding({
    required this.remoteSessionId,
    required this.generation,
    required this.channel,
  });

  final String remoteSessionId;
  final int generation;

  /// Compared by identity: the same channel object, not an equal one.
  final Object channel;

  bool matches(RemoteTouchBinding other) =>
      remoteSessionId == other.remoteSessionId &&
      generation == other.generation &&
      identical(channel, other.channel);
}

/// The Dart side of at most one remote touch.
///
/// The finger itself is the Android side's: this decides what may reach it.
/// A `touch_hold` is registered when it arrives and started when the command
/// queue gives it its turn; from then until the touch ends, the queue waits on
/// [run]. `touch_move`, `touch_release` and `touch_cancel` come straight here,
/// and are refused unless they name the running touch, come with its binding
/// and carry a `seq` greater than the last one.
///
/// ```text
/// queued      registered, waiting for its turn: the latest move and the
///             release are kept for it; a cancel ends it before it starts
/// started     the Android side has the finger
/// releasing   the release went to the Android side; nothing else is taken
/// cancelling  the cancel went to the Android side
/// ```
///
/// Every ack is sent at most once, whichever path gets to it first.
class RemoteTouchController {
  RemoteTouchController(
    this._accessibility, {
    void Function(String message)? log,
  }) : _log = log ?? _silent;

  final RemoteControlAccessibilityClient _accessibility;
  final void Function(String message) _log;

  _Touch? _touch;
  int _handles = 0;
  StreamSubscription<int>? _nativeEnds;

  /// Whether a touch is registered or running.
  bool get isActive => _touch != null;

  /// Registers [hold] as the touch, if there is none, and answers the sink the
  /// hold's ack must go through from now on, wherever it is sent from: the
  /// queue and this controller share it, and it sends once. `null` when a touch
  /// already exists: there is one finger.
  RemoteControlAckSink? register(
    RemoteTouchHoldCommand hold,
    RemoteTouchBinding binding,
    RemoteControlAckSink onAck,
  ) {
    _nativeEnds ??= _accessibility.touchEnds.listen(_onNativeEnd);
    if (_touch != null) return null;
    final touch = _Touch(hold, binding, _Reply(hold.id, onAck));
    _touch = touch;
    return touch.holdReply.send;
  }

  /// Starts [hold], which the queue has just given its turn, and completes when
  /// the touch has ended: the queue holds its place until then, whatever has
  /// been acknowledged.
  Future<void> run(
    RemoteTouchHoldCommand hold,
    RemoteControlAckSink onAck,
  ) async {
    final touch = _touch;
    if (touch == null ||
        !identical(touch.hold, hold) ||
        touch.phase != _Phase.queued) {
      // Cancelled or abandoned while it waited, or never registered.
      onAck(RemoteControlAck.failure(hold.id, RemoteControlError.touchEnded));
      return;
    }

    final handle = touch.handle = ++_handles;
    touch.phase = _Phase.started;
    _log('touch ${touch.name} started');
    final starting = _accessibility.startTouch(
      touch: handle,
      x: hold.x,
      y: hold.y,
    );

    // What arrived while it waited, in the order it would have gone: the latest
    // position, then the release.
    if (touch.queuedMove case (final move, final onMoveAck)) {
      touch.queuedMove = null;
      _sendMove(touch, move, onMoveAck);
    }
    if (touch.queuedRelease case (final release, final onReleaseAck)) {
      touch.queuedRelease = null;
      _sendRelease(touch, release, onReleaseAck);
    }

    _onStarted(touch, await starting);
    await touch.ended.future;
  }

  /// The queue refused [hold] or dropped it before its turn, and answered it
  /// itself. Anything else waiting for it is answered here.
  void drop(RemoteTouchHoldCommand hold) {
    final touch = _touch;
    if (touch != null && identical(touch.hold, hold)) {
      _end(touch, 'dropped', answerHold: false);
    }
  }

  void move(
    RemoteTouchMoveCommand move,
    RemoteTouchBinding binding,
    RemoteControlAckSink onAck,
  ) {
    final touch = _followed(move, binding);
    if (touch == null || touch.isFinishing) {
      onAck(_ended(move.id));
      return;
    }
    if (!_acceptSeq(touch, move)) {
      onAck(_ended(move.id));
      return;
    }
    if (touch.phase == _Phase.queued) {
      // Only the latest position matters, and a move that was taken gets no
      // ack: the one it replaces is simply never played.
      touch.queuedMove = (move, onAck);
      return;
    }
    _sendMove(touch, move, onAck);
  }

  void release(
    RemoteTouchReleaseCommand release,
    RemoteTouchBinding binding,
    RemoteControlAckSink onAck,
  ) {
    final touch = _followed(release, binding);
    if (touch == null || touch.isFinishing) {
      onAck(_ended(release.id));
      return;
    }
    if (!_acceptSeq(touch, release)) {
      onAck(_ended(release.id));
      return;
    }
    if (touch.phase == _Phase.queued) {
      touch.queuedMove = null;
      touch.queuedRelease = (release, onAck);
      return;
    }
    _sendRelease(touch, release, onAck);
  }

  /// Idempotent: a cancel for no touch, another touch or another binding is
  /// answered `ok` and changes nothing, since that touch is not running here.
  void cancel(
    RemoteTouchCancelCommand cancel,
    RemoteTouchBinding binding,
    RemoteControlAckSink onAck,
  ) {
    final touch = _followed(cancel, binding);
    if (touch == null) {
      onAck(RemoteControlAck.success(cancel.id));
      return;
    }
    if (!_acceptSeq(touch, cancel)) {
      onAck(_ended(cancel.id));
      return;
    }
    touch.cancelReplies.add(_Reply(cancel.id, onAck));
    switch (touch.phase) {
      case _Phase.queued:
        // The finger never goes down.
        _end(touch, 'cancel');
      case _Phase.releasing || _Phase.cancelling:
        // Answered when that ends: a final stroke cannot be recalled.
        return;
      case _Phase.started:
        touch.phase = _Phase.cancelling;
        unawaited(
          _accessibility
              .cancelTouch(touch: touch.handle!, seq: cancel.seq)
              .then((_) => _end(touch, 'cancel')),
        );
    }
  }

  /// Ends the touch now, without waiting for anything: the session, the
  /// channel or the peer connection it belonged to is gone. The Android side
  /// is told to take the finger away, and nobody waits for it.
  ///
  /// A touch still waiting for its turn is left for the queue to answer, which
  /// it does when it drops what is pending.
  void abandon() {
    final touch = _touch;
    if (touch == null) return;
    if (touch.phase == _Phase.queued) {
      _end(touch, 'abandoned', answerHold: false);
      return;
    }
    _abort(touch, 'abandoned');
  }

  Future<void> dispose() async {
    abandon();
    await _nativeEnds?.cancel();
    _nativeEnds = null;
  }

  // -------------------------------------------------------------- steps

  void _onStarted(_Touch touch, RemoteTouchStartOutcome outcome) {
    if (outcome == RemoteTouchStartOutcome.held) {
      if (identical(_touch, touch)) _log('touch ${touch.name} held');
      touch.holdReply.send(RemoteControlAck.success(touch.hold.id));
      return;
    }
    touch.holdReply.send(
      RemoteControlAck.failure(touch.hold.id, switch (outcome) {
        RemoteTouchStartOutcome.unsupported =>
          RemoteControlError.unsupportedCommand,
        RemoteTouchStartOutcome.unavailable =>
          RemoteControlError.accessibilityUnavailable,
        RemoteTouchStartOutcome.ended => RemoteControlError.touchEnded,
        RemoteTouchStartOutcome.revoked => RemoteControlError.sessionNotActive,
        RemoteTouchStartOutcome.rejected ||
        RemoteTouchStartOutcome.held => RemoteControlError.gestureRejected,
      }),
    );
    // A release or a cancel already on its way ends it when it is answered.
    if (identical(_touch, touch) && touch.phase == _Phase.started) {
      _abort(touch, 'hold ${outcome.name}');
    }
  }

  void _sendMove(
    _Touch touch,
    RemoteTouchMoveCommand move,
    RemoteControlAckSink onAck,
  ) {
    unawaited(
      _accessibility
          .moveTouch(touch: touch.handle!, seq: move.seq, x: move.x, y: move.y)
          .then((outcome) {
            if (outcome == RemoteTouchMoveOutcome.accepted) return;
            onAck(
              RemoteControlAck.failure(
                move.id,
                outcome == RemoteTouchMoveOutcome.unavailable
                    ? RemoteControlError.accessibilityUnavailable
                    : RemoteControlError.touchEnded,
              ),
            );
            // The Android side has already let it go.
            if (identical(_touch, touch) && touch.phase == _Phase.started) {
              _end(touch, 'ended on android');
            }
          }),
    );
  }

  void _sendRelease(
    _Touch touch,
    RemoteTouchReleaseCommand release,
    RemoteControlAckSink onAck,
  ) {
    touch.phase = _Phase.releasing;
    final reply = touch.releaseReply = _Reply(release.id, onAck);
    unawaited(
      _accessibility
          .releaseTouch(
            touch: touch.handle!,
            seq: release.seq,
            x: release.x,
            y: release.y,
          )
          .then((outcome) {
            reply.send(switch (outcome) {
              RemoteTouchReleaseOutcome.completed => RemoteControlAck.success(
                release.id,
              ),
              RemoteTouchReleaseOutcome.unavailable => RemoteControlAck.failure(
                release.id,
                RemoteControlError.accessibilityUnavailable,
              ),
              RemoteTouchReleaseOutcome.ended => _ended(release.id),
            });
            _end(
              touch,
              outcome == RemoteTouchReleaseOutcome.completed
                  ? 'released'
                  : 'release ${outcome.name}',
            );
          }),
    );
  }

  void _onNativeEnd(int handle) {
    final touch = _touch;
    // A release or a cancel in flight is answered by its own call.
    if (touch == null ||
        touch.handle != handle ||
        touch.phase != _Phase.started) {
      return;
    }
    _end(touch, 'ended on android');
  }

  // ------------------------------------------------------------ endings

  /// The touch ends here, and the Android side is told to let go of it.
  void _abort(_Touch touch, String reason) {
    final handle = touch.handle;
    if (handle != null) _accessibility.abandonTouch(touch: handle);
    _end(touch, reason);
  }

  /// Forgets the touch, answers everything still owed, and lets the queue go
  /// on. Every reply sends at most once, so whatever was answered stays so.
  ///
  /// With [answerHold] false the hold is left to the queue, which still holds
  /// it and answers it itself.
  void _end(_Touch touch, String reason, {bool answerHold = true}) {
    if (!identical(_touch, touch)) return;
    _touch = null;
    if (answerHold) touch.holdReply.send(_ended(touch.hold.id));
    if (touch.queuedRelease case (final release, final onAck)) {
      onAck(_ended(release.id));
    }
    touch.queuedRelease = null;
    touch.queuedMove = null;
    touch.releaseReply?.send(_ended(touch.releaseReply!.id));
    for (final reply in touch.cancelReplies) {
      reply.send(RemoteControlAck.success(reply.id));
    }
    _log(
      reason == 'released'
          ? 'touch ${touch.name} released'
          : 'touch ${touch.name} cancelled reason=$reason',
    );
    if (!touch.ended.isCompleted) touch.ended.complete();
  }

  // ----------------------------------------------------------- plumbing

  /// The running touch, if [command] is about it and comes with its binding.
  _Touch? _followed(RemoteTouchCommand command, RemoteTouchBinding binding) {
    final touch = _touch;
    if (touch == null ||
        touch.name != command.touch ||
        !touch.binding.matches(binding)) {
      return null;
    }
    return touch;
  }

  /// A `seq` that is not greater than the last one is a sender that has lost
  /// track of its finger, and the finger is taken away.
  bool _acceptSeq(_Touch touch, RemoteTouchFollowUpCommand command) {
    if (command.seq <= touch.lastSeq) {
      _abort(touch, 'sequence');
      return false;
    }
    touch.lastSeq = command.seq;
    return true;
  }

  static RemoteControlAck _ended(String id) =>
      RemoteControlAck.failure(id, RemoteControlError.touchEnded);

  static void _silent(String _) {}
}

enum _Phase { queued, started, releasing, cancelling }

class _Touch {
  _Touch(this.hold, this.binding, this.holdReply);

  final RemoteTouchHoldCommand hold;
  final RemoteTouchBinding binding;
  final _Reply holdReply;

  /// The sender's name for it. Never crosses the bridge.
  String get name => hold.touch;

  /// The Android side's name for it, once it has started.
  int? handle;

  _Phase phase = _Phase.queued;
  int lastSeq = 0;

  (RemoteTouchMoveCommand, RemoteControlAckSink)? queuedMove;
  (RemoteTouchReleaseCommand, RemoteControlAckSink)? queuedRelease;
  _Reply? releaseReply;
  final List<_Reply> cancelReplies = [];

  final Completer<void> ended = Completer<void>();

  /// A release or a cancel has been asked for: nothing else is taken.
  bool get isFinishing =>
      phase == _Phase.releasing ||
      phase == _Phase.cancelling ||
      queuedRelease != null;
}

/// One ack, sent at most once.
class _Reply {
  _Reply(this.id, this._sink);

  final String id;
  final RemoteControlAckSink _sink;
  bool settled = false;

  void send(RemoteControlAck ack) {
    if (settled) return;
    settled = true;
    _sink(ack);
  }
}
