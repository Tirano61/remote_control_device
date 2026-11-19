import 'package:remote_control_device/core/network/api_exception.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/data/datasources/device_auth_remote_data_source.dart';
import 'package:remote_control_device/features/device/data/models/device_login_request_model.dart';
import 'package:remote_control_device/features/device/data/repositories/failure_mapper.dart';
import 'package:remote_control_device/features/device/domain/entities/device_credentials.dart';
import 'package:remote_control_device/features/device/domain/entities/device_identity.dart';
import 'package:remote_control_device/features/device/domain/entities/device_session.dart';
import 'package:remote_control_device/features/device/domain/repositories/device_auth_repository.dart';

class DeviceAuthRepositoryImpl implements DeviceAuthRepository {
  const DeviceAuthRepositoryImpl({
    required DeviceAuthRemoteDataSource remoteDataSource,
    required DeviceTokenStore tokenStore,
  }) : _remoteDataSource = remoteDataSource,
       _tokenStore = tokenStore;

  final DeviceAuthRemoteDataSource _remoteDataSource;
  final DeviceTokenStore _tokenStore;

  @override
  Future<Result<DeviceSession>> login(DeviceCredentials credentials) async {
    // Read before the request leaves: whether authorisation was withdrawn
    // while it was on the wire is only known by comparing afterwards.
    final epoch = _tokenStore.epoch;
    try {
      final model = await _remoteDataSource.login(
        DeviceLoginRequestModel.fromCredentials(credentials),
      );
      final session = model.toEntity();
      // The token becomes the current session credential for every
      // device-authenticated request that follows — unless authorisation was
      // withdrawn in the meantime (a confirmed refusal, a stop, a newer
      // attempt). Then it is not installed: the caller that started this login
      // has been superseded, and its own generation check discards the answer.
      if (_tokenStore.epoch == epoch) _tokenStore.save(session.token);
      return Ok(session);
    } on ApiException catch (exception) {
      return Err(mapApiException(exception));
    }
  }

  @override
  Future<Result<DeviceIdentity>> checkStatus() async {
    try {
      final model = await _remoteDataSource.checkStatus();
      return Ok(model.toEntity());
    } on ApiException catch (exception) {
      return Err(mapApiException(exception));
    }
  }

  @override
  void endSession() => _tokenStore.clear();
}
