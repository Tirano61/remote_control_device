import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/domain/entities/device_activation.dart';
import 'package:remote_control_device/features/device/domain/entities/device_credentials.dart';
import 'package:remote_control_device/features/device/domain/entities/device_identity.dart';
import 'package:remote_control_device/features/device/domain/entities/device_session.dart';
import 'package:remote_control_device/features/device/domain/entities/device_technical_info.dart';
import 'package:remote_control_device/features/device/domain/repositories/device_auth_repository.dart';
import 'package:remote_control_device/features/device/domain/repositories/device_enrollment_repository.dart';
import 'package:remote_control_device/features/device/domain/services/device_info_provider.dart';
import 'package:remote_control_device/features/device/domain/storage/device_credentials_storage.dart';

/// Fixtures matching the shapes documented in `docs/backend/ENDPOINTS.md`.
const String testDeviceId = '550e8400-e29b-41d4-a716-446655440000';
const String testPublicId = '384-729-142';
const String testDeviceName = 'Tablet Tolva 01';
const String testDeviceSecret = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-ab';
const String testDeviceJwt = 'header.payload.signature';

const DeviceCredentials testCredentials = DeviceCredentials(
  deviceId: testDeviceId,
  deviceSecret: testDeviceSecret,
);

const DeviceIdentity testIdentity = DeviceIdentity(
  id: testDeviceId,
  publicId: testPublicId,
  name: testDeviceName,
  isActive: true,
);

const DeviceSession testSession = DeviceSession(
  device: testIdentity,
  token: testDeviceJwt,
);

const DeviceActivation testActivation = DeviceActivation(
  activated: true,
  deviceId: testDeviceId,
  publicId: testPublicId,
  name: testDeviceName,
  deviceSecret: testDeviceSecret,
);

/// In-memory stand-in for the Keystore-backed storage. Records every call so a
/// test can assert whether the credential was persisted or wiped.
class FakeDeviceCredentialsStorage implements DeviceCredentialsStorage {
  FakeDeviceCredentialsStorage([this.credentials]);

  DeviceCredentials? credentials;

  bool failOnRead = false;
  bool failOnWrite = false;

  int readCount = 0;
  int saveCount = 0;
  int clearCount = 0;

  @override
  Future<DeviceCredentials?> read() async {
    readCount++;
    if (failOnRead) {
      throw const DeviceCredentialsStorageException('forced read failure');
    }
    return credentials;
  }

  @override
  Future<void> save(DeviceCredentials credentials) async {
    saveCount++;
    if (failOnWrite) {
      throw const DeviceCredentialsStorageException('forced write failure');
    }
    this.credentials = credentials;
  }

  @override
  Future<void> clear() async {
    clearCount++;
    credentials = null;
  }
}

class FakeDeviceInfoProvider implements DeviceInfoProvider {
  FakeDeviceInfoProvider([this.info = DeviceTechnicalInfo.empty]);

  DeviceTechnicalInfo info;
  int collectCount = 0;

  @override
  Future<DeviceTechnicalInfo> collect() async {
    collectCount++;
    return info;
  }
}

class FakeDeviceEnrollmentRepository implements DeviceEnrollmentRepository {
  FakeDeviceEnrollmentRepository({this.result = const Ok(testActivation)});

  Result<DeviceActivation> result;

  String? lastPublicId;
  String? lastCode;
  DeviceTechnicalInfo? lastTechnicalInfo;
  int activateCount = 0;

  @override
  Future<Result<DeviceActivation>> activate({
    required String publicId,
    required String code,
    required DeviceTechnicalInfo technicalInfo,
  }) async {
    activateCount++;
    lastPublicId = publicId;
    lastCode = code;
    lastTechnicalInfo = technicalInfo;
    return result;
  }
}

class FakeDeviceAuthRepository implements DeviceAuthRepository {
  FakeDeviceAuthRepository({
    this.loginResult = const Ok(testSession),
    this.checkStatusResult = const Ok(testIdentity),
    this.tokenStore,
  });

  Result<DeviceSession> loginResult;
  Result<DeviceIdentity> checkStatusResult;

  /// Mirrors `DeviceAuthRepositoryImpl`, which installs the issued token as the
  /// current session token. Tests that care about *which* JWT the next call
  /// uses need that side effect.
  final DeviceTokenStore? tokenStore;

  DeviceCredentials? lastLoginCredentials;
  int loginCount = 0;
  int checkStatusCount = 0;
  int endSessionCount = 0;

  @override
  Future<Result<DeviceSession>> login(DeviceCredentials credentials) async {
    loginCount++;
    lastLoginCredentials = credentials;
    if (loginResult case Ok<DeviceSession>(:final value)) {
      tokenStore?.save(value.token);
    }
    return loginResult;
  }

  @override
  Future<Result<DeviceIdentity>> checkStatus() async {
    checkStatusCount++;
    return checkStatusResult;
  }

  @override
  void endSession() {
    endSessionCount++;
    tokenStore?.clear();
  }
}

/// Shorthands for the failure values the backend contract can produce.
const Err<DeviceSession> loginUnauthorized = Err<DeviceSession>(AuthFailure());
const Err<DeviceSession> loginUnreachable = Err<DeviceSession>(NetworkFailure());
const Err<DeviceIdentity> statusUnauthorized = Err<DeviceIdentity>(AuthFailure());
const Err<DeviceIdentity> statusUnreachable = Err<DeviceIdentity>(
  NetworkFailure(),
);
const Err<DeviceActivation> activationUnauthorized = Err<DeviceActivation>(
  AuthFailure(),
);
const Err<DeviceActivation> activationUnreachable = Err<DeviceActivation>(
  NetworkFailure(),
);

/// A second, distinct Device JWT: renewal tests have to prove the *new* token
/// reached the handshake, which a single fixture could not show.
const String testRenewedDeviceJwt = 'header.renewed-payload.signature';

const DeviceSession testRenewedSession = DeviceSession(
  device: testIdentity,
  token: testRenewedDeviceJwt,
);
