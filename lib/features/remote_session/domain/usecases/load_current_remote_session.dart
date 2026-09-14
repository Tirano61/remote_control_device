import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/repositories/remote_session_repository.dart';

/// Reads the authoritative remote-session state from the backend.
///
/// This is the only thing that establishes whether a session exists.
/// `remote-session:created` and `remote-session:closed` announce that something
/// changed; this call says what — which is what makes a lost event, a restart
/// and a reconnection all recover through the very same code path.
class LoadCurrentRemoteSession {
  const LoadCurrentRemoteSession(this._repository);

  final RemoteSessionRepository _repository;

  /// `Ok(null)` means the device has no live session.
  Future<Result<RemoteSession?>> call() => _repository.current();
}
