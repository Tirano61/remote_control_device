import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request.dart';
import 'package:remote_control_device/features/support/domain/repositories/support_repository.dart';

/// The user withdrew the request. Allowed from `WAITING`, `ASSIGNED` and
/// `ACCEPTED` — but the backend refuses it with `409` once a remote session
/// exists, and that refusal is answered by re-reading state, never by working
/// around it.
class CancelSupportRequest {
  const CancelSupportRequest(this._repository);

  final SupportRepository _repository;

  Future<Result<SupportRequest>> call(String id) => _repository.cancel(id);
}
