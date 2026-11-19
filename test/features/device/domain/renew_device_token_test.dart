import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';

import '../../../fakes/device_fakes.dart';

/// The renewal is shared by the REST side and the Socket.IO side (P36): both
/// may find an expired Device JWT at the same moment.
void main() {
  late DeviceTokenStore tokenStore;
  late FakeDeviceAuthRepository authRepository;
  late RenewDeviceToken renew;

  setUp(() {
    tokenStore = InMemoryDeviceTokenStore()..save(testDeviceJwt);
    authRepository = FakeDeviceAuthRepository(
      loginResult: const Ok(testRenewedSession),
      tokenStore: tokenStore,
    );
    renew = RenewDeviceToken(
      loadDeviceCredentials: LoadDeviceCredentials(
        FakeDeviceCredentialsStorage(testCredentials),
      ),
      authenticateDevice: AuthenticateDevice(authRepository),
    );
  });

  test('calls made while a login is on the wire share it: one login', () async {
    authRepository.loginGate = Completer<void>();
    final fromRest = renew();
    final fromSocket = renew();
    await Future<void>.delayed(Duration.zero);
    expect(authRepository.loginCount, 1);

    authRepository.loginGate!.complete();
    expect(await fromRest, const DeviceTokenRenewed(testRenewedDeviceJwt));
    expect(await fromSocket, const DeviceTokenRenewed(testRenewedDeviceJwt));
    expect(authRepository.loginCount, 1);
    expect(tokenStore.token, testRenewedDeviceJwt);
  });

  test('a call after the login answered starts a new one', () async {
    await renew();
    authRepository.loginResult = const Ok(testSession);
    expect(await renew(), const DeviceTokenRenewed(testDeviceJwt));
    expect(authRepository.loginCount, 2);
    expect(tokenStore.token, testDeviceJwt, reason: 'the later login wins');
  });

  test('a refusal is shared too, and does not stick', () async {
    authRepository.loginResult = loginRejected;
    authRepository.loginGate = Completer<void>();
    final a = renew();
    final b = renew();
    authRepository.loginGate!.complete();
    expect(await a, const DeviceTokenRejected());
    expect(await b, const DeviceTokenRejected());
    expect(authRepository.loginCount, 1);

    authRepository
      ..loginGate = null
      ..loginResult = const Ok(testRenewedSession);
    expect(await renew(), const DeviceTokenRenewed(testRenewedDeviceJwt));
    expect(authRepository.loginCount, 2);
  });
}
