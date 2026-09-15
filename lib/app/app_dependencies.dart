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
import 'package:remote_control_device/features/device/domain/realtime/device_realtime_channel.dart';
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
import 'package:remote_control_device/features/remote_session/data/datasources/remote_session_remote_data_source.dart';
import 'package:remote_control_device/features/remote_session/data/repositories/remote_session_repository_impl.dart';
import 'package:remote_control_device/features/remote_session/domain/repositories/remote_session_repository.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_device/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_device/features/support/data/datasources/support_remote_data_source.dart';
import 'package:remote_control_device/features/support/data/repositories/support_repository_impl.dart';
import 'package:remote_control_device/features/support/domain/repositories/support_repository.dart';
import 'package:remote_control_device/features/support/domain/usecases/accept_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/cancel_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/load_current_support_request.dart';
import 'package:remote_control_device/features/support/domain/usecases/reject_support_request.dart';
import 'package:remote_control_device/features/signaling/domain/signaling_client.dart';
import 'package:remote_control_device/features/webrtc/data/flutter_webrtc_peer_connection_factory.dart';
import 'package:remote_control_device/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_device/features/webrtc/domain/webrtc_peer_client.dart';
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
    required this.realtimeChannel,
    required this.requestSupport,
    required this.loadCurrentSupportRequest,
    required this.acceptSupportRequest,
    required this.rejectSupportRequest,
    required this.cancelSupportRequest,
    required this.loadCurrentRemoteSession,
    required this.closeRemoteSession,
    required this.peerConnectionFactory,
    required this.iceConfiguration,
  });

  factory AppDependencies.bootstrap({
    AppConfig? config,
    DeviceCredentialsStorage? credentialsStorage,
    DeviceInfoProvider? deviceInfoProvider,
    DeviceRealtimeChannel? realtimeChannel,
    WebRtcPeerConnectionFactory? peerConnectionFactory,
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
    // One [AuthenticatedDeviceRequest] for both features, so that several
    // endpoints hitting an expired Device JWT at the same moment share a single
    // login instead of starting one each.
    final SupportRepository supportRepository = SupportRepositoryImpl(
      remoteDataSource: SupportRemoteDataSourceImpl(apiClient),
      authenticatedRequest: authenticatedRequest,
    );
    final RemoteSessionRepository remoteSessionRepository =
        RemoteSessionRepositoryImpl(
          remoteDataSource: RemoteSessionRemoteDataSourceImpl(apiClient),
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
      realtimeChannel:
          realtimeChannel ??
          SocketIoDeviceRealtimeClient(config: resolvedConfig),
      requestSupport: RequestSupport(supportRepository),
      loadCurrentSupportRequest: LoadCurrentSupportRequest(supportRepository),
      acceptSupportRequest: AcceptSupportRequest(supportRepository),
      rejectSupportRequest: RejectSupportRequest(supportRepository),
      cancelSupportRequest: CancelSupportRequest(supportRepository),
      loadCurrentRemoteSession: LoadCurrentRemoteSession(
        remoteSessionRepository,
      ),
      closeRemoteSession: CloseRemoteSession(remoteSessionRepository),
      // Constructing it opens nothing either: no peer connection exists until
      // an offer arrives, and no media permission is involved at any point —
      // this build captures neither camera, microphone nor screen.
      peerConnectionFactory:
          peerConnectionFactory ?? const FlutterWebRtcPeerConnectionFactory(),
      iceConfiguration: WebRtcIceConfiguration.fromStunUrl(
        resolvedConfig.webRtcStunUrl,
      ),
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

  /// The single authenticated `/devices` socket.
  ///
  /// Owned by `DeviceRealtimeBloc`, which disposes it when it closes — so
  /// nothing else may dispose it, `SignalingBloc` included.
  ///
  /// This is the only place that knows the two ports below are one object.
  /// Every consumer is handed the narrow port it needs, which is what keeps the
  /// signaling feature from seeing connection signals and the realtime feature
  /// from seeing SDP.
  final DeviceRealtimeChannel realtimeChannel;

  /// The connection half: is the channel up, and what did it announce.
  DeviceRealtimeClient get realtimeClient => realtimeChannel;

  /// The signaling half: join a remote session, relay `webrtc:*`.
  DeviceSignalingClient get signalingClient => realtimeChannel;

  final RequestSupport requestSupport;
  final LoadCurrentSupportRequest loadCurrentSupportRequest;
  final AcceptSupportRequest acceptSupportRequest;
  final RejectSupportRequest rejectSupportRequest;
  final CancelSupportRequest cancelSupportRequest;

  final LoadCurrentRemoteSession loadCurrentRemoteSession;
  final CloseRemoteSession closeRemoteSession;

  /// Builds the peer connection that answers `remote_control_web`. The only
  /// reference to `flutter_webrtc` outside the WebRTC feature's data layer, and
  /// injectable so that tests exercise the negotiation without a native
  /// library no unit test can start.
  final WebRtcPeerConnectionFactory peerConnectionFactory;

  /// The ICE servers every peer connection is built with, read once from the
  /// compile-time environment. Empty means host candidates only.
  final WebRtcIceConfiguration iceConfiguration;
}
