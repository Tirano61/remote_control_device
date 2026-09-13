import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/features/device/domain/entities/device_identity.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/support/presentation/widgets/support_panel.dart';

/// The operational screen: who this device is, whether it is reachable, and the
/// assistance flow.
///
/// Only public information is rendered — never the `deviceSecret`, the Device
/// JWT, or any identifier used as proof of anything.
class ReadyPage extends StatelessWidget {
  const ReadyPage({required this.device, super.key});

  final DeviceIdentity device;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'ASISTENCIA REMOTA',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 32),
                  _Field(label: 'Dispositivo', value: device.publicId),
                  const SizedBox(height: 20),
                  _Field(label: 'Nombre', value: device.name),
                  const SizedBox(height: 20),
                  const _ConnectionField(),
                  const SizedBox(height: 28),
                  const Divider(),
                  const SizedBox(height: 20),
                  const SupportPanel(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Realtime channel state, in the plainest words available.
///
/// The distinction the user needs is "can the technician reach me right now",
/// so the five internal states collapse into four sentences. Nothing technical
/// crosses this boundary: no error code, no exception, and never a hint that
/// the reason was an expired token.
class _ConnectionField extends StatelessWidget {
  const _ConnectionField();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BlocBuilder<DeviceRealtimeBloc, DeviceRealtimeState>(
      builder: (context, state) {
        final (label, connected) = switch (state) {
          DeviceRealtimeConnected() => ('Conectado', true),
          DeviceRealtimeConnecting() => ('Conectando...', false),
          DeviceRealtimeReconnecting() => ('Reconectando...', false),
          DeviceRealtimeDisconnected() ||
          DeviceRealtimeConnectionError() => ('Sin conexión', false),
        };

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'CONEXIÓN',
              style: theme.textTheme.labelSmall?.copyWith(
                letterSpacing: 1.2,
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 12,
                  color: connected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                ),
                const SizedBox(width: 8),
                Text(label, style: theme.textTheme.titleMedium),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            letterSpacing: 1.2,
            color: theme.colorScheme.outline,
          ),
        ),
        const SizedBox(height: 4),
        Text(value, style: theme.textTheme.headlineSmall),
      ],
    );
  }
}
