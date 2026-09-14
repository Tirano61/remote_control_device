import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/repositories/remote_session_repository.dart';

/// The user of the tablet ends the assistance.
///
/// Reached only from a deliberate press on `FINALIZAR ASISTENCIA`. The [id] is
/// the one held in the state, which was built from an authenticated response —
/// never a value typed by the user and never one taken from a realtime payload.
class CloseRemoteSession {
  const CloseRemoteSession(this._repository);

  final RemoteSessionRepository _repository;

  Future<Result<RemoteSession>> call(String id) => _repository.close(id);
}
