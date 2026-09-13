import 'package:equatable/equatable.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request_status.dart';
import 'package:remote_control_device/features/support/domain/entities/support_technician.dart';

/// A request for assistance, as the backend holds it.
///
/// Only what this client actually acts on is modelled. `deviceId` is absent
/// because the device never sends or checks it — identity comes from the Device
/// JWT — and the timestamps are absent because nothing here reads them; adding
/// fields merely because the backend stores them would invent a contract this
/// application does not have.
class SupportRequest extends Equatable {
  const SupportRequest({
    required this.id,
    required this.status,
    this.technician,
  });

  /// Backend UUID, taken from an authenticated response and used to address the
  /// accept/reject/cancel endpoints. Never generated locally.
  final String id;

  final SupportRequestStatus status;

  /// Set from `ASSIGNED` onwards. `null` while nobody has taken the request —
  /// and also when an assigned request arrived without the documented
  /// technician block, which is read defensively rather than filled in.
  final SupportTechnician? technician;

  @override
  List<Object?> get props => [id, status, technician];
}
