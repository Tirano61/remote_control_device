import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request.dart';
import 'package:remote_control_device/features/support/domain/repositories/support_repository.dart';

/// Reads the authoritative support state from the backend.
///
/// This is the only thing that establishes what the device's request *is*.
/// Realtime events announce that something changed; this call says what.
/// Running it after every reconnection is what makes a missed
/// `support:assigned` harmless.
class LoadCurrentSupportRequest {
  const LoadCurrentSupportRequest(this._repository);

  final SupportRepository _repository;

  /// `Ok(null)` means the device has no active request.
  Future<Result<SupportRequest?>> call() => _repository.current();
}
