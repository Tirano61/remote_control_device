import 'package:remote_control_device/core/network/api_exception.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/device/data/network/authenticated_device_request.dart';
import 'package:remote_control_device/features/device/data/repositories/failure_mapper.dart';
import 'package:remote_control_device/features/support/data/datasources/support_remote_data_source.dart';
import 'package:remote_control_device/features/support/data/models/support_request_model.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request.dart';
import 'package:remote_control_device/features/support/domain/repositories/support_repository.dart';

/// Every call goes through [AuthenticatedDeviceRequest], so a Device JWT that
/// expired while the tablet sat idle costs one transparent re-login and one
/// repeat of the call — and a credential that was actually revoked ends in the
/// one re-enrollment path the application already has.
class SupportRepositoryImpl implements SupportRepository {
  const SupportRepositoryImpl({
    required SupportRemoteDataSource remoteDataSource,
    required AuthenticatedDeviceRequest authenticatedRequest,
  }) : _remoteDataSource = remoteDataSource,
       _authenticatedRequest = authenticatedRequest;

  final SupportRemoteDataSource _remoteDataSource;
  final AuthenticatedDeviceRequest _authenticatedRequest;

  @override
  Future<Result<SupportRequest>> create() => _request(_remoteDataSource.create);

  @override
  Future<Result<SupportRequest?>> current() async {
    try {
      final model = await _authenticatedRequest.run(_remoteDataSource.current);
      return Ok(model?.toEntity());
    } on ApiException catch (exception) {
      return Err(mapApiException(exception));
    }
  }

  @override
  Future<Result<SupportRequest>> accept(String id) =>
      _request(() => _remoteDataSource.accept(id));

  @override
  Future<Result<SupportRequest>> reject(String id) =>
      _request(() => _remoteDataSource.reject(id));

  @override
  Future<Result<SupportRequest>> cancel(String id) =>
      _request(() => _remoteDataSource.cancel(id));

  Future<Result<SupportRequest>> _request(
    Future<SupportRequestModel> Function() call,
  ) async {
    try {
      final model = await _authenticatedRequest.run(call);
      return Ok(model.toEntity());
    } on ApiException catch (exception) {
      return Err(mapApiException(exception));
    }
  }
}
