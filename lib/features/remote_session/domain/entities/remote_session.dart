import 'package:equatable/equatable.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_ended_by.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_technician.dart';

/// The remote assistance session the backend holds for this device.
///
/// Only what this client acts on or shows is modelled. The `device` block is
/// absent because the device never asserts its own identity — the Device JWT
/// does — and `createdAt` because nothing here reads it.
///
/// [endedAt] and [endedBy] are read for one purpose only: deciding whether the
/// answer to `POST /device/remote-sessions/:id/close` really confirms the close
/// of the session that was addressed (see [confirmsCloseOf]). The tablet still
/// learns that a session ended *in general* by no longer finding it in
/// `GET /device/remote-sessions/current`, and no screen or decision depends on
/// who closed it.
class RemoteSession extends Equatable {
  const RemoteSession({
    required this.id,
    required this.supportRequestId,
    required this.status,
    this.connectedAt,
    this.endedAt,
    this.endedBy,
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

  /// When the backend closed the session, as it sent it — UTC, written once by
  /// the first close, whoever made it. `null` while the session is live, and
  /// also when the value was absent or unreadable.
  ///
  /// Read, never produced, exactly like [connectedAt]. An idempotent repeat of
  /// the close answers the *original* instant, so this is never "now".
  final DateTime? endedAt;

  /// Who closed the session, as the backend recorded it. `null` while the
  /// session is live or when the field was absent; [RemoteSessionEndedBy.unknown]
  /// for a value this build does not know.
  ///
  /// Not necessarily `DEVICE` on the answer to this device's own close: the
  /// close is idempotent, and a session the technician or the backend (`SYSTEM`)
  /// had already closed keeps their `endedBy`. Nothing here requires one value
  /// or another — every value means the same to the tablet: the session is over.
  final RemoteSessionEndedBy? endedBy;

  /// Who is on the other end, when the payload carried the documented block.
  /// `null` costs the screen a name and nothing else — it never blocks showing
  /// that a session is live.
  final RemoteSessionTechnician? technician;

  /// Whether this payload, received as the answer to a close of
  /// [remoteSessionId], says that very session is closed at the backend.
  ///
  /// ```text
  /// same id          the close addressed this session; another id is not
  ///                  an answer about it
  /// status CLOSED    the backend holds it closed; ACTIVE, CONNECTING or a
  ///                  status this build cannot read are not a close
  /// endedAt present  every close the backend records writes it; a CLOSED
  ///                  without it is not the documented answer
  /// ```
  ///
  /// [endedBy] is deliberately not checked: the close is idempotent, so a
  /// confirmed close of this device's session may well say `TECHNICIAN` or
  /// `SYSTEM`.
  ///
  /// A `200` that fails this is treated as no confirmation at all. It never
  /// brings the session back either — the session stays ended on the tablet,
  /// and `/current` decides.
  bool confirmsCloseOf(String remoteSessionId) =>
      id == remoteSessionId &&
      status == RemoteSessionStatus.closed &&
      endedAt != null;

  @override
  List<Object?> get props => [
    id,
    supportRequestId,
    status,
    connectedAt,
    endedAt,
    endedBy,
    technician,
  ];
}
