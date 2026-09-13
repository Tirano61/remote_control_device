import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request.dart';
import 'package:remote_control_device/features/support/domain/repositories/support_repository.dart';

/// The user explicitly authorised the assigned technician.
///
/// Called from nowhere but a deliberate press on `PERMITIR`: consent is a
/// product-level security boundary, so no event, no reconnection and no
/// recovery path may reach this.
class AcceptSupportRequest {
  const AcceptSupportRequest(this._repository);

  final SupportRepository _repository;

  Future<Result<SupportRequest>> call(String id) => _repository.accept(id);
}
