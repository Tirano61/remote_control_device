import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/app/app_dependencies.dart';
import 'package:remote_control_device/app/device_gate.dart';
import 'package:remote_control_device/app/device_realtime_coordinator.dart';
import 'package:remote_control_device/app/remote_session_coordinator.dart';
import 'package:remote_control_device/app/support_coordinator.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_device/features/support/presentation/bloc/support/support_bloc.dart';

/// Holds the application-wide blocs and the coordinators that keep them in
/// step.
///
/// They are created here rather than by `BlocProvider.create` because each
/// coordinator needs several of them at once, and because closing them in
/// [State.dispose] is what releases the socket when the app goes away.
class RemoteControlApp extends StatefulWidget {
  const RemoteControlApp({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  State<RemoteControlApp> createState() => _RemoteControlAppState();
}

class _RemoteControlAppState extends State<RemoteControlApp> {
  late final DeviceSessionBloc _sessionBloc;
  late final DeviceRealtimeBloc _realtimeBloc;
  late final SupportBloc _supportBloc;
  late final RemoteSessionBloc _remoteSessionBloc;
  late final DeviceRealtimeCoordinator _realtimeCoordinator;
  late final SupportCoordinator _supportCoordinator;
  late final RemoteSessionCoordinator _remoteSessionCoordinator;

  @override
  void initState() {
    super.initState();
    final dependencies = widget.dependencies;

    _sessionBloc = DeviceSessionBloc(
      loadDeviceCredentials: dependencies.loadDeviceCredentials,
      authenticateDevice: dependencies.authenticateDevice,
      checkDeviceStatus: dependencies.checkDeviceStatus,
      clearDeviceCredentials: dependencies.clearDeviceCredentials,
    );
    _realtimeBloc = DeviceRealtimeBloc(
      client: dependencies.realtimeClient,
      tokenStore: dependencies.tokenStore,
      renewDeviceToken: dependencies.renewDeviceToken,
      reauthRetryDelay: dependencies.config.realtimeReauthRetryDelay,
    );
    _supportBloc = SupportBloc(
      requestSupport: dependencies.requestSupport,
      loadCurrentSupportRequest: dependencies.loadCurrentSupportRequest,
      acceptSupportRequest: dependencies.acceptSupportRequest,
      rejectSupportRequest: dependencies.rejectSupportRequest,
      cancelSupportRequest: dependencies.cancelSupportRequest,
    );
    _remoteSessionBloc = RemoteSessionBloc(
      loadCurrentRemoteSession: dependencies.loadCurrentRemoteSession,
      closeRemoteSession: dependencies.closeRemoteSession,
    );

    _realtimeCoordinator = DeviceRealtimeCoordinator(
      sessionBloc: _sessionBloc,
      realtimeBloc: _realtimeBloc,
      credentialRevocation: dependencies.credentialRevocation,
    )..start();
    _supportCoordinator = SupportCoordinator(
      realtimeClient: dependencies.realtimeClient,
      realtimeBloc: _realtimeBloc,
      sessionBloc: _sessionBloc,
      supportBloc: _supportBloc,
    )..start();
    _remoteSessionCoordinator = RemoteSessionCoordinator(
      realtimeClient: dependencies.realtimeClient,
      realtimeBloc: _realtimeBloc,
      sessionBloc: _sessionBloc,
      supportBloc: _supportBloc,
      remoteSessionBloc: _remoteSessionBloc,
    )..start();

    _sessionBloc.add(const DeviceSessionStarted());
  }

  @override
  void dispose() {
    _remoteSessionCoordinator.dispose();
    _supportCoordinator.dispose();
    _realtimeCoordinator.dispose();
    // Closing the realtime bloc also disposes the socket, so no connection
    // outlives the session it belonged to.
    _realtimeBloc.close();
    _remoteSessionBloc.close();
    _supportBloc.close();
    _sessionBloc.close();
    widget.dependencies.credentialRevocation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<DeviceSessionBloc>.value(value: _sessionBloc),
        BlocProvider<DeviceRealtimeBloc>.value(value: _realtimeBloc),
        BlocProvider<SupportBloc>.value(value: _supportBloc),
        BlocProvider<RemoteSessionBloc>.value(value: _remoteSessionBloc),
      ],
      child: MaterialApp(
        title: 'Asistencia remota',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00629B)),
        ),
        home: DeviceGate(dependencies: widget.dependencies),
      ),
    );
  }
}
