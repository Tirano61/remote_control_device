import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request.dart';
import 'package:remote_control_device/features/support/domain/repositories/support_repository.dart';

/// The user pressed "request assistance".
class RequestSupport {
  const RequestSupport(this._repository);

  final SupportRepository _repository;

  Future<Result<SupportRequest>> call() => _repository.create();
}
