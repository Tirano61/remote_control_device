import 'dart:async';

import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_technician.dart';
import 'package:remote_control_device/features/remote_session/domain/repositories/remote_session_repository.dart';
import 'package:remote_control_device/features/remote_session/domain/storage/ended_remote_session_store.dart';

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

/// `connectedAt` exactly as the backend documents it: UTC, written once by
/// `POST /remote-sessions/:id/activate` from the server clock.
const String testConnectedAtWire = '2026-03-11T09:34:02.000Z';

const RemoteSession activeSession = RemoteSession(
  id: testRemoteSessionId,
  supportRequestId: testSupportRequestId,
  status: RemoteSessionStatus.active,
  technician: testRemoteSessionTechnician,
);

/// The same session as [activeSession] with the activation instant the backend
/// sends. `DateTime` cannot be `const`, which is the only reason this is a
/// separate fixture.
final RemoteSession activatedSession = RemoteSession(
  id: testRemoteSessionId,
  supportRequestId: testSupportRequestId,
  status: RemoteSessionStatus.active,
  connectedAt: DateTime.parse(testConnectedAtWire),
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
  String? connectedAt,
}) => <String, dynamic>{
  'id': id,
  'supportRequestId': testSupportRequestId,
  'status': status,
  'createdAt': '2026-03-11T09:33:41.000Z',
  'connectedAt': connectedAt,
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

  /// When set, a read decides its answer the moment it is made — what the
  /// backend said then — and delivers it only once the test completes this:
  /// a response still on the wire while other things happen.
  Completer<void>? currentGate;

  @override
  Future<Result<RemoteSession?>> current() async {
    currentCount++;
    final answer = currentQueue.isNotEmpty
        ? currentQueue.removeAt(0)
        : currentResult;
    final gate = currentGate;
    if (gate != null) await gate.future;
    return answer;
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
const Ok<RemoteSession?> activeRemoteSession = Ok<RemoteSession?>(
  activeSession,
);
final Ok<RemoteSession?> activatedRemoteSession = Ok<RemoteSession?>(
  activatedSession,
);
const Err<RemoteSession?> remoteSessionUnreachable = Err<RemoteSession?>(
  NetworkFailure(),
);
const Err<RemoteSession> closeUnreachable = Err<RemoteSession>(
  NetworkFailure(),
);
const Err<RemoteSession> closeConflict = Err<RemoteSession>(ConflictFailure());
const Err<RemoteSession> closeNotFound = Err<RemoteSession>(NotFoundFailure());

/// An [EndedRemoteSessionStore] in memory. Sharing one instance between two
/// blocs is how a test stands for the application being killed and opened
/// again: the second bloc starts with nothing but what was stored.
class FakeEndedRemoteSessionStore implements EndedRemoteSessionStore {
  FakeEndedRemoteSessionStore([this.value, this.closeOwed = true]);

  /// The stored session id, or `null`.
  String? value;

  /// Whether the stored marker owes the backend a close (FINALIZAR) or not
  /// (ended because authority was lost). Meaningless while [value] is null.
  bool closeOwed;

  /// Every operation that reached the store, in order: `'read'`,
  /// `('write', id)` and `'clear'`.
  final List<Object> calls = [];

  /// When true, every operation throws, as a store that cannot be reached.
  bool failing = false;

  @override
  Future<EndedRemoteSessionMarker?> read() async {
    calls.add('read');
    if (failing) throw const EndedRemoteSessionStoreException('test');
    final id = value;
    return id == null
        ? null
        : EndedRemoteSessionMarker(id, closeOwed: closeOwed);
  }

  @override
  Future<void> write(EndedRemoteSessionMarker marker) async {
    calls.add(('write', marker.remoteSessionId));
    if (failing) throw const EndedRemoteSessionStoreException('test');
    value = marker.remoteSessionId;
    closeOwed = marker.closeOwed;
  }

  @override
  Future<void> clear() async {
    calls.add('clear');
    if (failing) throw const EndedRemoteSessionStoreException('test');
    value = null;
    closeOwed = true;
  }
}
