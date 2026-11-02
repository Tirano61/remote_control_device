import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';
import 'package:remote_control_device/features/remote_control/presentation/bloc/remote_control_accessibility/remote_control_accessibility_bloc.dart';

/// One line about the accessibility service, and the way to enable it if it is
/// off.
///
/// The button only opens Android's settings. Android requires the user to
/// enable the service there, and nothing here tries to do it for them.
class RemoteControlStatus extends StatelessWidget {
  const RemoteControlStatus({super.key});

  static const Key lineKey = Key('remote-control-status-line');
  static const Key enableButtonKey = Key('remote-control-enable-button');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BlocBuilder<
      RemoteControlAccessibilityBloc,
      RemoteControlAccessibilityState
    >(
      builder: (context, state) {
        final status = state.status;
        if (status == null) return const SizedBox.shrink();

        final enabled = status == RemoteControlAccessibilityStatus.available;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 4),
            Text(
              enabled
                  ? 'Control remoto: habilitado'
                  : 'Control remoto: requiere habilitar accesibilidad',
              key: lineKey,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            if (!enabled) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                key: enableButtonKey,
                onPressed: () => context
                    .read<RemoteControlAccessibilityBloc>()
                    .add(const RemoteControlAccessibilitySettingsRequested()),
                child: const Text('HABILITAR CONTROL REMOTO'),
              ),
            ],
          ],
        );
      },
    );
  }
}
