import 'package:remote_control_device/core/config/app_config.dart';
import 'package:remote_control_device/core/network/api_client.dart';
import 'package:remote_control_device/core/session/device_token_store.dart';
import 'package:remote_control_device/features/device/data/datasources/device_auth_remote_data_source.dart';
import 'package:remote_control_device/features/device/data/datasources/device_enrollment_remote_data_source.dart';
import 'package:remote_control_device/features/device/data/datasources/platform_device_info_provider.dart';
import 'package:remote_control_device/features/device/data/repositories/device_auth_repository_impl.dart';
import 'package:remote_control_device/features/device/data/repositories/device_enrollment_repository_impl.dart';
import 'package:remote_control_device/features/device/data/storage/secure_device_credentials_storage.dart';
import 'package:remote_control_device/features/device/domain/repositories/device_auth_repository.dart';
import 'package:remote_control_device/features/device/domain/repositories/device_enrollment_repository.dart';
import 'package:remote_control_device/features/device/domain/services/device_info_provider.dart';
import 'package:remote_control_device/features/device/domain/storage/device_credentials_storage.dart';
import 'package:remote_control_device/features/device/domain/usecases/authenticate_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/check_device_status.dart';
import 'package:remote_control_device/features/device/domain/usecases/clear_device_credentials.dart';
import 'package:remote_control_device/features/device/domain/usecases/enroll_device.dart';
import 'package:remote_control_device/features/device/domain/usecases/load_device_credentials.dart';

/// Composition root. Wiring lives here so that no layer has to reach for a
/// global service locator, and so tests can build the same graph with fakes.
class AppDependencies {
  AppDependencies._({
    required this.config,
    required this.tokenStore,
    required this.credentialsStorage,
    required this.enrollDevice,
    required this.loadDeviceCredentials,
    required this.clearDeviceCredentials,
    required this.authenticateDevice,
    required this.checkDeviceStatus,
  });

  factory AppDependencies.bootstrap({
    AppConfig? config,
    DeviceCredentialsStorage? credentialsStorage,
    DeviceInfoProvider? deviceInfoProvider,
  }) {
    final resolvedConfig = config ?? AppConfig.fromEnvironment();
    final tokenStore = InMemoryDeviceTokenStore();
    final apiClient = ApiClient(config: resolvedConfig, tokenStore: tokenStore);

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

    return AppDependencies._(
      config: resolvedConfig,
      tokenStore: tokenStore,
      credentialsStorage: storage,
      enrollDevice: EnrollDevice(
        repository: enrollmentRepository,
        credentialsStorage: storage,
        deviceInfoProvider: infoProvider,
      ),
      loadDeviceCredentials: LoadDeviceCredentials(storage),
      clearDeviceCredentials: ClearDeviceCredentials(
        credentialsStorage: storage,
        authRepository: authRepository,
      ),
      authenticateDevice: AuthenticateDevice(authRepository),
      checkDeviceStatus: CheckDeviceStatus(authRepository),
    );
  }

  final AppConfig config;
  final DeviceTokenStore tokenStore;
  final DeviceCredentialsStorage credentialsStorage;

  final EnrollDevice enrollDevice;
  final LoadDeviceCredentials loadDeviceCredentials;
  final ClearDeviceCredentials clearDeviceCredentials;
  final AuthenticateDevice authenticateDevice;
  final CheckDeviceStatus checkDeviceStatus;
}
