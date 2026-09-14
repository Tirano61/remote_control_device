import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';

/// The device half of the remote-session contract.
///
/// Both methods address the session of the *authenticated* device: no
/// `deviceId` and no `supportRequestId` is ever sent as proof of ownership, and
/// the id passed to [close] comes from a session this client received over an
/// authenticated call.
abstract interface class RemoteSessionRepository {
  /// `GET /device/remote-sessions/current` — the live session of this device,
  /// or `Ok(null)` when there is none.
  ///
  /// "No session" is a documented, successful answer and not a failure: a
  /// request the user accepted before the technician pressed "start" has no
  /// session yet, and that is the normal case rather than an error.
  Future<Result<RemoteSession?>> current();

  /// `POST /device/remote-sessions/:id/close` — the user of the tablet ends the
  /// assistance. Answers the `CLOSED` session; the backend completes the
  /// support request in the same transaction.
  Future<Result<RemoteSession>> close(String id);
}
