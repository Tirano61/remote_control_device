import 'package:remote_control_device/core/network/api_exception.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/device/data/network/authenticated_device_request.dart';
import 'package:remote_control_device/features/device/data/repositories/failure_mapper.dart';
import 'package:remote_control_device/features/remote_session/data/datasources/remote_session_remote_data_source.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/repositories/remote_session_repository.dart';

/// Both calls go through [AuthenticatedDeviceRequest], the same instance the
/// support endpoints use, so an expired Device JWT costs one transparent
/// re-login and one repeat of the call — and a permanent credential that was
/// actually revoked ends in the one re-enrollment path the application has.
/// None of that logic is duplicated here.
class RemoteSessionRepositoryImpl implements RemoteSessionRepository {
  const RemoteSessionRepositoryImpl({
    required RemoteSessionRemoteDataSource remoteDataSource,
    required AuthenticatedDeviceRequest authenticatedRequest,
  }) : _remoteDataSource = remoteDataSource,
       _authenticatedRequest = authenticatedRequest;

  final RemoteSessionRemoteDataSource _remoteDataSource;
  final AuthenticatedDeviceRequest _authenticatedRequest;

  @override
  Future<Result<RemoteSession?>> current() async {
    try {
      final model = await _authenticatedRequest.run(_remoteDataSource.current);
      return Ok(model?.toEntity());
    } on ApiException catch (exception) {
      return Err(mapApiException(exception));
    }
  }

  @override
  Future<Result<RemoteSession>> close(String id) async {
    try {
      final model = await _authenticatedRequest.run(
        () => _remoteDataSource.close(id),
      );
      return Ok(model.toEntity());
    } on ApiException catch (exception) {
      return Err(mapApiException(exception));
    }
  }
}
