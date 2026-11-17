import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:remote_control_device/features/remote_session/domain/storage/ended_remote_session_store.dart';

/// [EndedRemoteSessionStore] on the same Android-Keystore-backed store the
/// device credentials use.
///
/// The value is not secret — a `remoteSessionId` grants nothing — so the
/// choice is about not adding a second persistence package for one key, not
/// about confidentiality. It lives under its own key, so clearing the device
/// credentials on a re-enrollment does not erase it: a session ended here stays
/// refused even if this installation becomes a device again.
class SecureEndedRemoteSessionStore implements EndedRemoteSessionStore {
  const SecureEndedRemoteSessionStore({FlutterSecureStorage? secureStorage})
    : _storage = secureStorage ?? const FlutterSecureStorage();

  static const String endedRemoteSessionKey = 'remote_session.ended_pending';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() async {
    try {
      final value = await _storage.read(key: endedRemoteSessionKey);
      return value == null || value.isEmpty ? null : value;
    } on Exception catch (error) {
      throw EndedRemoteSessionStoreException(
        'read failed: ${error.runtimeType}',
      );
    }
  }

  @override
  Future<void> write(String remoteSessionId) async {
    try {
      await _storage.write(key: endedRemoteSessionKey, value: remoteSessionId);
    } on Exception catch (error) {
      throw EndedRemoteSessionStoreException(
        'write failed: ${error.runtimeType}',
      );
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: endedRemoteSessionKey);
    } on Exception catch (error) {
      throw EndedRemoteSessionStoreException(
        'delete failed: ${error.runtimeType}',
      );
    }
  }
}
