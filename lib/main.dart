import 'package:flutter/material.dart';
import 'package:remote_control_device/app/app_dependencies.dart';
import 'package:remote_control_device/app/remote_control_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(RemoteControlApp(dependencies: AppDependencies.bootstrap()));
}
