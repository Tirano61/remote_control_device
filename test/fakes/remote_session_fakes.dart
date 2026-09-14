import 'dart:async';

import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_technician.dart';
import 'package:remote_control_device/features/remote_session/domain/repositories/remote_session_repository.dart';

import 'support_fakes.dart';

/// Fixtures taken verbatim from the payloads in `docs/backend/ENDPOINTS.md`.
const String testRemoteSessionId = '3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10';
const String testOtherRemoteSessionId = '0f0f0f0f-1111-4111-8111-222222222222';

const RemoteSessionTechnician testRemoteSessionTechnician =
    RemoteSessionTechnician(id: testTechnicianId, name: testTechnicianName);

const RemoteSession connectingSession = RemoteSession(
  id: testRemoteSessionId,
  supportRequestId: testSupportRequestId,
  status: RemoteSessionStatus.connecting,
  technician: testRemoteSessionTechnician,
);

const RemoteSession activeSession = RemoteSession(
  id: testRemoteSessionId,
  supportRequestId: testSupportRequestId,
  status: RemoteSessionStatus.active,
  technician: testRemoteSessionTechnician,
);

const RemoteSession closedSession = RemoteSession(
  id: testRemoteSessionId,
  supportRequestId: testSupportRequestId,
  status: RemoteSessionStatus.closed,
  technician: testRemoteSessionTechnician,
);

/// The `remoteSession` object as the backend documents it, including the fields
/// this client deliberately ignores.
Map<String, dynamic> remoteSessionJson({
  String id = testRemoteSessionId,
  String status = 'CONNECTING',
  bool withTechnician = true,
  String? endedBy,
}) => <String, dynamic>{
  'id': id,
  'supportRequestId': testSupportRequestId,
  'status': status,
  'createdAt': '2026-03-11T09:33:41.000Z',
  'connectedAt': null,
  'endedAt': endedBy == null ? null : '2026-03-11T09:41:02.000Z',
  'endedBy': endedBy,
  'device': <String, dynamic>{
    'id': '550e8400-e29b-41d4-a716-446655440000',
    'publicId': '384-729-142',
    'name': 'Tablet Tolva 01',
    'isOnline': true,
  },
  'technician': withTechnician
      ? <String, dynamic>{'id': testTechnicianId, 'name': testTechnicianName}
      : null,
};

/// The `GET /device/remote-sessions/current` envelope.
Map<String, dynamic> currentRemoteSessionEnvelope(
  Map<String, dynamic>? session,
) => <String, dynamic>{'remoteSession': session};

/// Records every call and answers with whatever the test scripted, so the bloc
/// can be driven through the whole lifecycle without HTTP.
class FakeRemoteSessionRepository implements RemoteSessionRepository {
  FakeRemoteSessionRepository({
    this.currentResult = const Ok<RemoteSession?>(null),
    this.closeResult = const Ok(closedSession),
  });

  Result<RemoteSession?> currentResult;
  Result<RemoteSession> closeResult;

  int currentCount = 0;
  int closeCount = 0;

  /// Ids the client addressed, in order. Used to prove the client only ever
  /// acts on an id it received from the backend.
  final List<String> closedIds = [];

  /// Answers scripted one call at a time, consumed before [currentResult].
  /// Lets a test say "this read answers a session, the next one answers none".
  final List<Result<RemoteSession?>> currentQueue = [];

  /// When set, [close] does not answer until the test completes it. The only
  /// way to observe the state *while* a close is in flight.
  Completer<void>? closeGate;

  @override
  Future<Result<RemoteSession?>> current() async {
    currentCount++;
    if (currentQueue.isNotEmpty) return currentQueue.removeAt(0);
    return currentResult;
  }

  @override
  Future<Result<RemoteSession>> close(String id) async {
    closeCount++;
    closedIds.add(id);
    await closeGate?.future;
    return closeResult;
  }
}

const Ok<RemoteSession?> noRemoteSession = Ok<RemoteSession?>(null);
const Ok<RemoteSession?> connectingRemoteSession = Ok<RemoteSession?>(
  connectingSession,
);
const Ok<RemoteSession?> activeRemoteSession = Ok<RemoteSession?>(activeSession);
const Err<RemoteSession?> remoteSessionUnreachable = Err<RemoteSession?>(
  NetworkFailure(),
);
const Err<RemoteSession> closeUnreachable = Err<RemoteSession>(
  NetworkFailure(),
);
const Err<RemoteSession> closeConflict = Err<RemoteSession>(ConflictFailure());
const Err<RemoteSession> closeNotFound = Err<RemoteSession>(NotFoundFailure());
