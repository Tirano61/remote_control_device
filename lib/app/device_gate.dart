import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/app/app_dependencies.dart';
import 'package:remote_control_device/features/device/presentation/bloc/enrollment/enrollment_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';
import 'package:remote_control_device/features/device/presentation/pages/connection_error_page.dart';
import 'package:remote_control_device/features/device/presentation/pages/credential_refused_page.dart';
import 'package:remote_control_device/features/device/presentation/pages/enrollment_page.dart';
import 'package:remote_control_device/features/device/presentation/pages/ready_page.dart';
import 'package:remote_control_device/features/device/presentation/pages/startup_page.dart';

/// Single place where the application-wide device state decides what is shown.
/// No screen re-derives that decision for itself.
class DeviceGate extends StatelessWidget {
  const DeviceGate({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DeviceSessionBloc, DeviceSessionState>(
      builder: (context, state) {
        void add(DeviceSessionEvent event) =>
            context.read<DeviceSessionBloc>().add(event);

        return switch (state) {
          DeviceSessionInitial() || DeviceSessionCheckingLocalCredentials() =>
            const StartupPage(message: 'Verificando activación...'),
          DeviceSessionAuthenticating() => const StartupPage(
            message: 'Conectando con el servidor...',
          ),
          DeviceSessionNotEnrolled() => _enrollment(),
          DeviceSessionReEnrolling() => _enrollment(
            onCancel: () => add(const DeviceSessionReEnrollmentCancelled()),
          ),
          DeviceSessionReady(:final device) => ReadyPage(device: device),
          DeviceSessionCredentialRefused() => CredentialRefusedPage(
            onRetry: () => add(const DeviceSessionRetryRequested()),
            onReEnroll: () => add(const DeviceSessionReEnrollmentRequested()),
          ),
          DeviceSessionAuthenticationUnavailable(:final failure) =>
            ConnectionErrorPage(
              failure: failure,
              onRetry: () => add(const DeviceSessionRetryRequested()),
            ),
        };
      },
    );
  }

  /// [onCancel] is given only when an enrollment is already stored, which is
  /// also what makes the form warn that it will be replaced.
  Widget _enrollment({VoidCallback? onCancel}) => BlocProvider(
    // A fresh bloc per visit, so a previous failure never carries over.
    create: (_) => EnrollmentBloc(enrollDevice: dependencies.enrollDevice),
    child: EnrollmentPage(onCancel: onCancel),
  );
}
