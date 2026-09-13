import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/app/app_dependencies.dart';
import 'package:remote_control_device/app/device_gate.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';

class RemoteControlApp extends StatelessWidget {
  const RemoteControlApp({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => DeviceSessionBloc(
        loadDeviceCredentials: dependencies.loadDeviceCredentials,
        authenticateDevice: dependencies.authenticateDevice,
        checkDeviceStatus: dependencies.checkDeviceStatus,
        clearDeviceCredentials: dependencies.clearDeviceCredentials,
      )..add(const DeviceSessionStarted()),
      child: MaterialApp(
        title: 'Asistencia remota',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00629B)),
        ),
        home: DeviceGate(dependencies: dependencies),
      ),
    );
  }
}
