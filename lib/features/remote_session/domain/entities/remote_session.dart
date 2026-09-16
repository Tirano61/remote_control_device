import 'package:equatable/equatable.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_technician.dart';

/// The remote assistance session the backend holds for this device.
///
/// Only what this client acts on or shows is modelled. The `device` block is
/// absent because the device never asserts its own identity — the Device JWT
/// does — and `createdAt`, `endedAt` and `endedBy` are absent because nothing
/// here reads them: the tablet learns that a session ended by no longer finding
/// it in `GET /device/remote-sessions/current`, not by inspecting how it ended.
/// Modelling fields merely because the backend stores them would invent a
/// contract this application does not have.
class RemoteSession extends Equatable {
  const RemoteSession({
    required this.id,
    required this.supportRequestId,
    required this.status,
    this.connectedAt,
    this.technician,
  });

  /// Backend UUID, taken from an authenticated response and used to address
  /// `POST /device/remote-sessions/:id/close`. Never generated locally, never
  /// typed by the user, and never adopted from a realtime payload.
  final String id;

  /// The `ACCEPTED` support request that authorised this session. Carried so
  /// that a session can be matched against the request the screen is showing,
  /// and so it can be logged: both are operational identifiers, not
  /// credentials.
  final String supportRequestId;

  final RemoteSessionStatus status;

  /// When the backend recorded that the remote connection came up, as it sent
  /// it — UTC, written once by `POST /remote-sessions/:id/activate` from the
  /// server clock.
  ///
  /// Read, never produced. This client does not ask for the transition, does
  /// not time it and does not fill this in when the backend left it `null`: a
  /// session that is `CONNECTING` has no connection instant, and one this
  /// tablet invented would be a claim about something it did not observe.
  final DateTime? connectedAt;

  /// Who is on the other end, when the payload carried the documented block.
  /// `null` costs the screen a name and nothing else — it never blocks showing
  /// that a session is live.
  final RemoteSessionTechnician? technician;

  @override
  List<Object?> get props => [
    id,
    supportRequestId,
    status,
    connectedAt,
    technician,
  ];
}
