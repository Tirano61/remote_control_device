import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/device/data/storage/secure_device_credentials_storage.dart';
import 'package:remote_control_device/features/remote_session/data/storage/secure_ended_remote_session_store.dart';
import 'package:remote_control_device/features/remote_session/domain/storage/ended_remote_session_store.dart';

import '../../../fakes/device_fakes.dart';
import '../../../fakes/remote_session_fakes.dart';

/// The package's in-memory test platform, as in the credentials storage test.
/// The real Android Keystore belongs on a device.
void main() {
  const store = SecureEndedRemoteSessionStore();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('read is null when nothing was ever ended here', () async {
    expect(await store.read(), isNull);
  });

  test('write then read round-trips the session id', () async {
    await store.write(const EndedRemoteSessionMarker(testRemoteSessionId));

    expect(
      await store.read(),
      const EndedRemoteSessionMarker(testRemoteSessionId),
    );
  });

  test('clear forgets it', () async {
    await store.write(const EndedRemoteSessionMarker(testRemoteSessionId));

    await store.clear();

    expect(await store.read(), isNull);
  });

  test('clearing the device credentials leaves the marker in place', () async {
    // A re-enrollment wipes the credential; a session ended here must stay
    // refused even if this installation becomes a device again.
    const credentials = SecureDeviceCredentialsStorage();
    await credentials.save(testCredentials);
    await store.write(const EndedRemoteSessionMarker(testRemoteSessionId));

    await credentials.clear();

    expect(
      await store.read(),
      const EndedRemoteSessionMarker(testRemoteSessionId),
    );
  });

  test('an end by lost authority is remembered as owing no close', () async {
    await store.write(
      const EndedRemoteSessionMarker(testRemoteSessionId, closeOwed: false),
    );

    expect(
      await store.read(),
      const EndedRemoteSessionMarker(testRemoteSessionId, closeOwed: false),
    );

    // FINALIZAR on another session afterwards owes a close again.
    await store.write(const EndedRemoteSessionMarker(testOtherRemoteSessionId));
    expect(
      await store.read(),
      const EndedRemoteSessionMarker(testOtherRemoteSessionId),
    );
  });

  test('a marker of an older build, without the cause, owes a close', () async {
    FlutterSecureStorage.setMockInitialValues({
      SecureEndedRemoteSessionStore.endedRemoteSessionKey: testRemoteSessionId,
    });

    expect(
      await store.read(),
      const EndedRemoteSessionMarker(testRemoteSessionId),
    );
  });

  test('clear forgets the cause too', () async {
    await store.write(
      const EndedRemoteSessionMarker(testRemoteSessionId, closeOwed: false),
    );

    await store.clear();

    expect(await const FlutterSecureStorage().readAll(), isEmpty);
  });

  test('only the session id is stored, under its own key', () async {
    await store.write(const EndedRemoteSessionMarker(testRemoteSessionId));

    final raw = await const FlutterSecureStorage().readAll();
    expect(raw, {
      SecureEndedRemoteSessionStore.endedRemoteSessionKey: testRemoteSessionId,
    });
  });
}
