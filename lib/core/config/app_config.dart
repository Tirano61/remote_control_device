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
  });

  /// Builds the configuration from the compile-time environment.
  factory AppConfig.fromEnvironment() =>
      const AppConfig(backendBaseUrl: _backendBaseUrlFromEnvironment);

  static const String defaultBackendBaseUrl = 'http://10.0.2.2:3000';

  static const String _backendBaseUrlFromEnvironment = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: defaultBackendBaseUrl,
  );

  /// Root of the `remote_control_backend` HTTP server.
  ///
  /// The backend registers no global prefix, so routes hang directly off this
  /// URL (`<baseUrl>/device-auth/login`).
  final String backendBaseUrl;

  final Duration connectTimeout;
  final Duration sendTimeout;
  final Duration receiveTimeout;
}
