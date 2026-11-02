import 'package:equatable/equatable.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';

/// A frame from the `control` channel, once decoded.
///
/// There are only two outcomes worth reporting upward, and a frame with no
/// recoverable id is neither: nothing can be answered to it, so it stops at the
/// decoder.
sealed class RemoteControlInboundMessage extends Equatable {
  const RemoteControlInboundMessage();
}

/// A well-formed command. Not yet authorised to run.
final class RemoteControlCommandReceived extends RemoteControlInboundMessage {
  const RemoteControlCommandReceived(this.command);

  final RemoteControlCommand command;

  @override
  List<Object?> get props => [command];
}

/// A message that named itself with an [id] and could not be accepted.
final class RemoteControlMessageRejected extends RemoteControlInboundMessage {
  const RemoteControlMessageRejected(this.id, this.error);

  final String id;
  final RemoteControlError error;

  @override
  List<Object?> get props => [id, error];
}
