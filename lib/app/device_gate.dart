import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/app/app_dependencies.dart';
import 'package:remote_control_device/features/device/presentation/bloc/enrollment/enrollment_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';
import 'package:remote_control_device/features/device/presentation/pages/connection_error_page.dart';
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
      builder: (context, state) => switch (state) {
        DeviceSessionInitial() || DeviceSessionCheckingLocalCredentials() =>
          const StartupPage(message: 'Verificando activación...'),
        DeviceSessionAuthenticating() => const StartupPage(
          message: 'Conectando con el servidor...',
        ),
        DeviceSessionNotEnrolled() => _enrollment(),
        DeviceSessionReEnrollmentRequired() => _enrollment(
          reEnrollmentRequired: true,
        ),
        DeviceSessionReady(:final device) => ReadyPage(device: device),
        DeviceSessionNetworkError(:final failure) => ConnectionErrorPage(
          failure: failure,
          onRetry: () => context.read<DeviceSessionBloc>().add(
            const DeviceSessionRetryRequested(),
          ),
        ),
      },
    );
  }

  Widget _enrollment({bool reEnrollmentRequired = false}) => BlocProvider(
    // A fresh bloc per visit, so a previous failure never carries over.
    create: (_) => EnrollmentBloc(enrollDevice: dependencies.enrollDevice),
    child: EnrollmentPage(reEnrollmentRequired: reEnrollmentRequired),
  );
}
