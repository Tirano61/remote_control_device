import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:remote_control_device/features/remote_session/domain/storage/ended_remote_session_store.dart';

/// [EndedRemoteSessionStore] on the same Android-Keystore-backed store the
/// device credentials use.
///
/// The value is not secret — a `remoteSessionId` grants nothing — so the
/// choice is about not adding a second persistence package for one key, not
/// about confidentiality. It lives under its own keys, so clearing the device
/// credentials on a re-enrollment does not erase it: a session ended here stays
/// refused even if this installation becomes a device again.
///
/// Three keys:
///
/// ```text
/// remote_session.ended_pending         the remoteSessionId
/// remote_session.ended_pending_cause   absent: a close is owed (FINALIZAR)
///                                      "authorityLost": none is owed
/// remote_session.held                  the remoteSessionId this tablet last
///                                      took part in, written before it could
///                                      be controlled (Prompt 45)
/// ```
///
/// A marker written by a build older than the second key reads as "close
/// owed", which is exactly what every marker of those builds meant.
class SecureEndedRemoteSessionStore implements EndedRemoteSessionStore {
  const SecureEndedRemoteSessionStore({FlutterSecureStorage? secureStorage})
    : _storage = secureStorage ?? const FlutterSecureStorage();

  static const String endedRemoteSessionKey = 'remote_session.ended_pending';
  static const String endedRemoteSessionCauseKey =
      'remote_session.ended_pending_cause';
  static const String authorityLostCause = 'authorityLost';
  static const String heldRemoteSessionKey = 'remote_session.held';

  final FlutterSecureStorage _storage;

  @override
  Future<EndedRemoteSessionMarker?> read() async {
    try {
      final id = await _storage.read(key: endedRemoteSessionKey);
      if (id == null || id.isEmpty) return null;
      final cause = await _storage.read(key: endedRemoteSessionCauseKey);
      return EndedRemoteSessionMarker(
        id,
        closeOwed: cause != authorityLostCause,
      );
    } on Exception catch (error) {
      throw EndedRemoteSessionStoreException(
        'read failed: ${error.runtimeType}',
      );
    }
  }

  @override
  Future<void> write(EndedRemoteSessionMarker marker) async {
    try {
      // The cause first: interrupted between the two writes, the worst left
      // behind is a cause with no id, which reads as no marker at all.
      if (marker.closeOwed) {
        await _storage.delete(key: endedRemoteSessionCauseKey);
      } else {
        await _storage.write(
          key: endedRemoteSessionCauseKey,
          value: authorityLostCause,
        );
      }
      await _storage.write(
        key: endedRemoteSessionKey,
        value: marker.remoteSessionId,
      );
    } on Exception catch (error) {
      throw EndedRemoteSessionStoreException(
        'write failed: ${error.runtimeType}',
      );
    }
  }

  @override
  Future<String?> readHeld() async {
    try {
      final id = await _storage.read(key: heldRemoteSessionKey);
      return id == null || id.isEmpty ? null : id;
    } on Exception catch (error) {
      throw EndedRemoteSessionStoreException(
        'held read failed: ${error.runtimeType}',
      );
    }
  }

  @override
  Future<void> writeHeld(String remoteSessionId) async {
    try {
      await _storage.write(key: heldRemoteSessionKey, value: remoteSessionId);
    } on Exception catch (error) {
      throw EndedRemoteSessionStoreException(
        'held write failed: ${error.runtimeType}',
      );
    }
  }

  @override
  Future<void> clearHeld() async {
    try {
      await _storage.delete(key: heldRemoteSessionKey);
    } on Exception catch (error) {
      throw EndedRemoteSessionStoreException(
        'held delete failed: ${error.runtimeType}',
      );
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: endedRemoteSessionKey);
      await _storage.delete(key: endedRemoteSessionCauseKey);
    } on Exception catch (error) {
      throw EndedRemoteSessionStoreException(
        'delete failed: ${error.runtimeType}',
      );
    }
  }
}
