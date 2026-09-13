/// Single source of truth for environment-dependent configuration.
///
/// The backend base URL is injected at compile time so that development and
/// production builds differ only by a `--dart-define`, without introducing a
/// flavor system this early in the project:
///
/// ```text
/// flutter run   --dart-define=BACKEND_BASE_URL=http://192.168.1.50:3000
/// flutter build apk --dart-define=BACKEND_BASE_URL=https://api.example.com
/// ```
///
/// The default value points at `10.0.2.2`, which is how the Android emulator
/// reaches `localhost` on the host machine running `remote_control_backend`.
class AppConfig {
  const AppConfig({
    required this.backendBaseUrl,
    this.connectTimeout = const Duration(seconds: 10),
    this.sendTimeout = const Duration(seconds: 15),
    this.receiveTimeout = const Duration(seconds: 15),
    this.realtimeConnectTimeout = const Duration(seconds: 10),
    this.realtimeReconnectionDelay = const Duration(seconds: 2),
    this.realtimeReconnectionDelayMax = const Duration(seconds: 20),
    this.realtimeReauthRetryDelay = const Duration(seconds: 15),
  });

  /// Builds the configuration from the compile-time environment.
  factory AppConfig.fromEnvironment() =>
      const AppConfig(backendBaseUrl: _backendBaseUrlFromEnvironment);

  static const String defaultBackendBaseUrl = 'http://10.0.2.2:3000';

  static const String _backendBaseUrlFromEnvironment = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: defaultBackendBaseUrl,
  );

  /// Socket.IO namespace this client is allowed to use, per `REALTIME.md`.
  /// `/technicians` belongs to `remote_control_web` and is never opened here.
  static const String deviceRealtimeNamespace = '/devices';

  /// Root of the `remote_control_backend` HTTP server.
  ///
  /// The backend registers no global prefix, so routes hang directly off this
  /// URL (`<baseUrl>/device-auth/login`).
  final String backendBaseUrl;

  final Duration connectTimeout;
  final Duration sendTimeout;
  final Duration receiveTimeout;

  /// How long a single Socket.IO connection attempt may take before it is
  /// treated as failed.
  final Duration realtimeConnectTimeout;

  /// Delay before the first reconnection attempt. Each further attempt doubles
  /// it, up to [realtimeReconnectionDelayMax]. Kept in the seconds range on
  /// purpose: a tablet with no network must not hammer the radio.
  final Duration realtimeReconnectionDelay;

  final Duration realtimeReconnectionDelayMax;

  /// Delay before retrying a Device JWT renewal that could not be completed
  /// because the backend was unreachable.
  final Duration realtimeReauthRetryDelay;

  /// URL of the `/devices` namespace, in the form `socket_io_client` expects.
  ///
  /// That package derives the namespace from the *path* of the URL it is given,
  /// so the namespace is appended to the same base URL the HTTP client uses
  /// rather than configured separately. This is the only place the two are
  /// joined; the realtime infrastructure never builds a URL of its own.
  ///
  /// It follows that the base URL must be the server root — which it is, since
  /// the backend registers no global prefix. A base URL carrying a path would
  /// make `socket_io_client` read that path as part of the namespace.
  String get deviceRealtimeUrl =>
      '${backendBaseUrl.replaceAll(RegExp(r'/+$'), '')}'
      '$deviceRealtimeNamespace';
}
