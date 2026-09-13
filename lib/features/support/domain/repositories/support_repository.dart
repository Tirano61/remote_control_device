import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request.dart';

/// The device half of the support-request contract.
///
/// Every method addresses the request of the *authenticated* device: no
/// `deviceId` is sent anywhere, and the ids passed in come from responses this
/// client received over an authenticated call.
abstract interface class SupportRepository {
  /// `POST /support-requests` — asks for assistance. Answers a `WAITING`
  /// request.
  Future<Result<SupportRequest>> create();

  /// `GET /support-requests/current` — the authoritative state of this device's
  /// support request. `Ok(null)` means there is none, which is a normal answer
  /// and not a failure.
  Future<Result<SupportRequest?>> current();

  /// `POST /support-requests/:id/accept` — the user authorises the technician.
  Future<Result<SupportRequest>> accept(String id);

  /// `POST /support-requests/:id/reject` — the user refuses the technician.
  Future<Result<SupportRequest>> reject(String id);

  /// `POST /support-requests/:id/cancel` — the user withdraws the request.
  Future<Result<SupportRequest>> cancel(String id);
}
