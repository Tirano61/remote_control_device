import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request_status.dart';
import 'package:remote_control_device/features/support/domain/entities/support_technician.dart';
import 'package:remote_control_device/features/support/domain/repositories/support_repository.dart';

/// Fixtures taken verbatim from the payloads in `docs/backend/ENDPOINTS.md`.
const String testSupportRequestId = '8f14e45f-ceea-4d3c-b4e2-2f4b3c9a1d77';
const String testOtherSupportRequestId = '1a2b3c4d-0000-4000-8000-abcdefabcdef';
const String testTechnicianId = '7c9e6679-7425-40de-944b-e07fc1f90ae7';
const String testTechnicianName = 'Ana Torres';

const SupportTechnician testTechnician = SupportTechnician(
  id: testTechnicianId,
  name: testTechnicianName,
);

const SupportRequest waitingRequest = SupportRequest(
  id: testSupportRequestId,
  status: SupportRequestStatus.waiting,
);

const SupportRequest assignedRequest = SupportRequest(
  id: testSupportRequestId,
  status: SupportRequestStatus.assigned,
  technician: testTechnician,
);

const SupportRequest acceptedRequest = SupportRequest(
  id: testSupportRequestId,
  status: SupportRequestStatus.accepted,
  technician: testTechnician,
);

const SupportRequest rejectedRequest = SupportRequest(
  id: testSupportRequestId,
  status: SupportRequestStatus.rejected,
  technician: testTechnician,
);

const SupportRequest cancelledRequest = SupportRequest(
  id: testSupportRequestId,
  status: SupportRequestStatus.cancelled,
);

/// The `supportRequest` object as the backend documents it, including the
/// fields this client deliberately ignores.
Map<String, dynamic> supportRequestJson({
  String id = testSupportRequestId,
  String status = 'WAITING',
  bool withTechnician = false,
}) => <String, dynamic>{
  'id': id,
  'deviceId': '550e8400-e29b-41d4-a716-446655440000',
  'status': status,
  'technicianId': withTechnician ? testTechnicianId : null,
  'technician': withTechnician
      ? <String, dynamic>{'id': testTechnicianId, 'name': testTechnicianName}
      : null,
  'createdAt': '2026-03-11T09:30:00.000Z',
  'assignedAt': withTechnician ? '2026-03-11T09:31:12.000Z' : null,
  'respondedAt': null,
  'closedAt': null,
};

/// The `GET /support-requests/current` envelope.
Map<String, dynamic> currentEnvelope(Map<String, dynamic>? request) =>
    <String, dynamic>{'supportRequest': request};

/// Records every call and answers with whatever the test scripted, so the bloc
/// can be driven through the flow without HTTP.
class FakeSupportRepository implements SupportRepository {
  FakeSupportRepository({
    this.createResult = const Ok(waitingRequest),
    this.currentResult = const Ok<SupportRequest?>(null),
    this.acceptResult = const Ok(acceptedRequest),
    this.rejectResult = const Ok(rejectedRequest),
    this.cancelResult = const Ok(cancelledRequest),
  });

  Result<SupportRequest> createResult;
  Result<SupportRequest?> currentResult;
  Result<SupportRequest> acceptResult;
  Result<SupportRequest> rejectResult;
  Result<SupportRequest> cancelResult;

  int createCount = 0;
  int currentCount = 0;
  int acceptCount = 0;
  int rejectCount = 0;
  int cancelCount = 0;

  /// Ids the client addressed, in order. Used to prove the client only ever
  /// acts on an id it received from the backend.
  final List<String> actedOnIds = [];

  @override
  Future<Result<SupportRequest>> create() async {
    createCount++;
    return createResult;
  }

  @override
  Future<Result<SupportRequest?>> current() async {
    currentCount++;
    return currentResult;
  }

  @override
  Future<Result<SupportRequest>> accept(String id) async {
    acceptCount++;
    actedOnIds.add(id);
    return acceptResult;
  }

  @override
  Future<Result<SupportRequest>> reject(String id) async {
    rejectCount++;
    actedOnIds.add(id);
    return rejectResult;
  }

  @override
  Future<Result<SupportRequest>> cancel(String id) async {
    cancelCount++;
    actedOnIds.add(id);
    return cancelResult;
  }
}

const Err<SupportRequest> supportUnreachable = Err<SupportRequest>(
  NetworkFailure(),
);
const Err<SupportRequest?> currentUnreachable = Err<SupportRequest?>(
  NetworkFailure(),
);
const Err<SupportRequest> supportConflict = Err<SupportRequest>(
  ConflictFailure(),
);
const Err<SupportRequest> supportNotFound = Err<SupportRequest>(
  NotFoundFailure(),
);
