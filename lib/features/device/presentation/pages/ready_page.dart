import 'package:flutter/material.dart';
import 'package:remote_control_device/features/device/domain/entities/device_identity.dart';

/// Minimal operational screen.
///
/// Deliberately shows no "request assistance" action: that belongs to a later
/// prompt. Only public information is rendered — never the `deviceSecret` nor
/// the Device JWT.
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
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'ASISTENCIA REMOTA',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(letterSpacing: 2),
                  ),
                  const SizedBox(height: 40),
                  _Field(label: 'Dispositivo', value: device.publicId),
                  const SizedBox(height: 24),
                  _Field(label: 'Nombre', value: device.name),
                  const SizedBox(height: 24),
                  const _Field(label: 'Estado', value: 'Listo'),
                  const SizedBox(height: 40),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.check_circle,
                        color: theme.colorScheme.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text('Dispositivo listo', style: theme.textTheme.bodyLarge),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
