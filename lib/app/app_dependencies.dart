import 'package:remote_control_device/core/config/app_config.dart';
import 'package:remote_control_device/core/network/api_client.dart';
import 'package:remote_control_device/core/session/device_credential_revocation.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/data/datasources/device_auth_remote_data_source.dart';
import 'package:remote_control_device/features/device/data/datasources/device_enrollment_remote_data_source.dart';
import 'package:remote_control_device/features/device/data/datasources/platform_device_info_provider.dart';
import 'package:remote_control_device/features/device/data/network/authenticated_device_request.dart';
import 'package:remote_control_device/features/device/data/repositories/device_auth_repository_impl.dart';
import 'package:remote_control_device/features/device/data/realtime/socket_io_device_realtime_client.dart';
import 'package:remote_control_device/features/device/data/repositories/device_enrollment_repository_impl.dart';
import 'package:remote_control_device/features/device/data/storage/secure_device_credentials_storage.dart';
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_client.dart';
import 'package:remote_control_device/features/device/domain/repositories/device_auth_repository.dart';
import 'package:remote_control_device/features/device/domain/repositories/device_enrollment_repository.dart';
import 'package:remote_control_device/features/device/domain/services/device_info_provider.dart';
import 'package:remote_control_device/features/device/domain/storage/device_credentials_storage.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/check_device_status.dart';
import 'package:remote_control_device/features/device/domain/usecases/clear_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/enroll_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/renew_device_token.dart';
import 'package:remote_control_device/features/support/data/datasources/support_remote_data_source.dart';
import 'package:remote_control_device/features/support/data/repositories/support_repository_impl.dart';
import 'package:remote_control_device/features/support/domain/repositories/support_repository.dart';
import 'package:remote_control_device/features/support/domain/usecases/accept_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/cancel_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/load_current_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/reject_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/request_support.dart';

/// Composition root. Wiring lives here so that no layer has to reach for a
/// global service locator, and so tests can build the same graph with fakes.
class AppDependencies {
  AppDependencies._({
    required this.config,
    required this.tokenStore,
    required this.credentialsStorage,
    required this.credentialRevocation,
    required this.enrollDevice,
    required this.loadDeviceCredentials,
    required this.clearDeviceCredentials,
    required this.authenticateDevice,
    required this.checkDeviceStatus,
    required this.renewDeviceToken,
    required this.realtimeClient,
    required this.requestSupport,
    required this.loadCurrentSupportRequest,
    required this.acceptSupportRequest,
    required this.rejectSupportRequest,
    required this.cancelSupportRequest,
  });

  factory AppDependencies.bootstrap({
    AppConfig? config,
    DeviceCredentialsStorage? credentialsStorage,
    DeviceInfoProvider? deviceInfoProvider,
    DeviceRealtimeClient? realtimeClient,
  }) {
    final resolvedConfig = config ?? AppConfig.fromEnvironment();
    final tokenStore = InMemoryDeviceTokenStore();
    final apiClient = ApiClient(config: resolvedConfig, tokenStore: tokenStore);
    final credentialRevocation = DeviceCredentialRevocation();

    final storage = credentialsStorage ?? const SecureDeviceCredentialsStorage();
    final infoProvider = deviceInfoProvider ?? PlatformDeviceInfoProvider();

    final DeviceEnrollmentRepository enrollmentRepository =
        DeviceEnrollmentRepositoryImpl(
          DeviceEnrollmentRemoteDataSourceImpl(apiClient),
        );
    final DeviceAuthRepository authRepository = DeviceAuthRepositoryImpl(
      remoteDataSource: DeviceAuthRemoteDataSourceImpl(apiClient),
      tokenStore: tokenStore,
    );

    final loadDeviceCredentials = LoadDeviceCredentials(storage);
    final authenticateDevice = AuthenticateDevice(authRepository);
    final renewDeviceToken = RenewDeviceToken(
      loadDeviceCredentials: loadDeviceCredentials,
      authenticateDevice: authenticateDevice,
    );

    // The same renewal the realtime layer uses, reached from the HTTP side.
    final authenticatedRequest = AuthenticatedDeviceRequest(
      renewDeviceToken: renewDeviceToken,
      revocation: credentialRevocation,
    );
    final SupportRepository supportRepository = SupportRepositoryImpl(
      remoteDataSource: SupportRemoteDataSourceImpl(apiClient),
      authenticatedRequest: authenticatedRequest,
    );

    return AppDependencies._(
      config: resolvedConfig,
      tokenStore: tokenStore,
      credentialsStorage: storage,
      credentialRevocation: credentialRevocation,
      enrollDevice: EnrollDevice(
        repository: enrollmentRepository,
        credentialsStorage: storage,
        deviceInfoProvider: infoProvider,
      ),
      loadDeviceCredentials: loadDeviceCredentials,
      clearDeviceCredentials: ClearDeviceCredentials(
        credentialsStorage: storage,
        authRepository: authRepository,
      ),
      authenticateDevice: authenticateDevice,
      checkDeviceStatus: CheckDeviceStatus(authRepository),
      renewDeviceToken: renewDeviceToken,
      // Constructing it opens nothing: the socket is only built on connect().
      realtimeClient:
          realtimeClient ?? SocketIoDeviceRealtimeClient(config: resolvedConfig),
      requestSupport: RequestSupport(supportRepository),
      loadCurrentSupportRequest: LoadCurrentSupportRequest(supportRepository),
      acceptSupportRequest: AcceptSupportRequest(supportRepository),
      rejectSupportRequest: RejectSupportRequest(supportRepository),
      cancelSupportRequest: CancelSupportRequest(supportRepository),
    );
  }

  final AppConfig config;
  final DeviceTokenStore tokenStore;
  final DeviceCredentialsStorage credentialsStorage;

  /// Where a revoked permanent credential is reported, from wherever it was
  /// discovered. Owned here; closed with the application.
  final DeviceCredentialRevocation credentialRevocation;

  final EnrollDevice enrollDevice;
  final LoadDeviceCredentials loadDeviceCredentials;
  final ClearDeviceCredentials clearDeviceCredentials;
  final AuthenticateDevice authenticateDevice;
  final CheckDeviceStatus checkDeviceStatus;
  final RenewDeviceToken renewDeviceToken;

  /// Owned by `DeviceRealtimeBloc`, which disposes it when it closes.
  final DeviceRealtimeClient realtimeClient;

  final RequestSupport requestSupport;
  final LoadCurrentSupportRequest loadCurrentSupportRequest;
  final AcceptSupportRequest acceptSupportRequest;
  final RejectSupportRequest rejectSupportRequest;
  final CancelSupportRequest cancelSupportRequest;
}
