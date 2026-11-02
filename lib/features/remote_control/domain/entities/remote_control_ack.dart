import 'package:equatable/equatable.dart';
import 'package:remote_control_device/features/remote_control/domain/entities/remote_control_error.dart';

/// The answer to one command, sent back on the channel it arrived on.
///
/// `ok` is only ever true after Android reported the gesture completed. Having
/// asked for it is not having done it.
class RemoteControlAck extends Equatable {
  const RemoteControlAck.success(this.id) : ok = true, error = null;

  const RemoteControlAck.failure(this.id, RemoteControlError this.error)
    : ok = false;

  /// The id of the command this answers, exactly as it was received.
  final String id;

  final bool ok;

  /// Set exactly when [ok] is false.
  final RemoteControlError? error;

  @override
  List<Object?> get props => [id, ok, error];
}
