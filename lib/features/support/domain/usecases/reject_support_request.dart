import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request.dart';
import 'package:remote_control_device/features/support/domain/repositories/support_repository.dart';

/// The user refused the assigned technician. Terminal for that request.
class RejectSupportRequest {
  const RejectSupportRequest(this._repository);

  final SupportRepository _repository;

  Future<Result<SupportRequest>> call(String id) => _repository.reject(id);
}
