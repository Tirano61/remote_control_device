import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/device/data/storage/secure_device_credentials_storage.dart';
import 'package:remote_control_device/features/device/domain/entities/device_credentials.dart';

import '../../../fakes/device_fakes.dart';

/// These tests use the package's own in-memory test platform. The real Android
/// Keystore is deliberately not exercised here — that belongs on a device.
void main() {
  const storage = SecureDeviceCredentialsStorage();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('read returns null when nothing was ever stored', () async {
    expect(await storage.read(), isNull);
  });

  test('save then read round-trips the credential', () async {
    await storage.save(testCredentials);

    expect(await storage.read(), testCredentials);
  });

  test('clear removes both keys', () async {
    await storage.save(testCredentials);

    await storage.clear();

    expect(await storage.read(), isNull);
    expect(
      await const FlutterSecureStorage().read(
        key: SecureDeviceCredentialsStorage.deviceSecretKey,
      ),
      isNull,
    );
  });

  test('a half-written pair is reported as "not enrolled"', () async {
    // Only the id survived; without the secret the device cannot authenticate.
    FlutterSecureStorage.setMockInitialValues({
      SecureDeviceCredentialsStorage.deviceIdKey: testDeviceId,
    });

    expect(await storage.read(), isNull);
  });

  test('the secret is written under the secure store, not alongside it', () async {
    await storage.save(
      const DeviceCredentials(deviceId: testDeviceId, deviceSecret: 'top-secret'),
    );

    final raw = await const FlutterSecureStorage().readAll();
    expect(raw[SecureDeviceCredentialsStorage.deviceSecretKey], 'top-secret');
    expect(raw[SecureDeviceCredentialsStorage.deviceIdKey], testDeviceId);
  });

  group('architecture', () {
    test('flutter_secure_storage is imported by exactly one file', () async {
      // Everything else must go through the DeviceCredentialsStorage port, so
      // the secret cannot leak into SharedPreferences, a file or a database.
      final offenders = <String>[];

      await for (final entity in Directory('lib').list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = await entity.readAsString();
        if (source.contains('package:flutter_secure_storage/')) {
          offenders.add(entity.path.replaceAll(r'\', '/'));
        }
      }

      expect(offenders, [
        'lib/features/device/data/storage/secure_device_credentials_storage.dart',
      ]);
    });

    test('no presentation code reads the deviceSecret field', () async {
      // Domain entities and the storage port may model it; blocs, pages and
      // widgets must never touch it. Comments that mention it are fine, so
      // they are stripped before the check.
      final offenders = <String>[];

      await for (final entity in Directory('lib/features/device/presentation')
          .list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final code = (await entity.readAsLines())
            .where((line) => !line.trimLeft().startsWith('//'))
            .join('\n');
        if (code.contains('deviceSecret')) {
          offenders.add(entity.path.replaceAll(r'\', '/'));
        }
      }

      expect(offenders, isEmpty);
    });
  });
}
