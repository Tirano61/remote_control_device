import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/app/app_dependencies.dart';
import 'package:remote_control_device/app/device_gate.dart';
import 'package:remote_control_device/app/device_realtime_coordinator.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';

/// Holds the two application-wide blocs and the coordinator that keeps them in
/// step.
///
/// They are created here rather than by `BlocProvider.create` because the
/// coordinator needs both of them at once, and because closing them in
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
  late final DeviceRealtimeCoordinator _coordinator;

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
    _coordinator = DeviceRealtimeCoordinator(
      sessionBloc: _sessionBloc,
      realtimeBloc: _realtimeBloc,
    )..start();

    _sessionBloc.add(const DeviceSessionStarted());
  }

  @override
  void dispose() {
    _coordinator.dispose();
    // Closing the realtime bloc also disposes the socket, so no connection
    // outlives the session it belonged to.
    _realtimeBloc.close();
    _sessionBloc.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<DeviceSessionBloc>.value(value: _sessionBloc),
        BlocProvider<DeviceRealtimeBloc>.value(value: _realtimeBloc),
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
