import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/features/remote_control/domain/remote_control_accessibility_client.dart';
import 'package:remote_control_device/features/remote_control/presentation/bloc/remote_control_accessibility/remote_control_accessibility_bloc.dart';

/// Whether the technician may act on this tablet right now, as far as the
/// assistance goes. Decided by the caller from the session, never from the
/// accessibility service: the service stays enabled between assistances and
/// says nothing about whether anyone is authorised today.
enum RemoteControlAuthorization {
  /// `ACTIVE`, confirmed with the backend: commands run.
  authorized,

  /// The session exists but is not `ACTIVE` yet.
  pending,

  /// The tablet cannot confirm the session with the backend right now
  /// (reconnecting, or reconnected and not yet reconciled). Nothing runs.
  suspended,

  /// Android stopped the screen capture in this assistance; control was
  /// withdrawn with it and does not come back in this assistance.
  revoked,
}

/// One line about remote control, and the way to enable the accessibility
/// service if it is off.
///
/// The button only opens Android's settings. Android requires the user to
/// enable the service there, and nothing here tries to do it for them.
///
/// "habilitado" is said only when both halves hold: the service is enabled
/// *and* the assistance is [RemoteControlAuthorization.authorized]. An enabled
/// service under a suspended or withdrawn authorisation says so instead.
class RemoteControlStatus extends StatelessWidget {
  const RemoteControlStatus({required this.authorization, super.key});

  static const Key lineKey = Key('remote-control-status-line');
  static const Key enableButtonKey = Key('remote-control-enable-button');

  final RemoteControlAuthorization authorization;

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
        // A withdrawn or suspended authorisation is the fact that matters,
        // whatever the service's state; enabling it would not change it.
        final line = switch (authorization) {
          RemoteControlAuthorization.revoked =>
            'Control remoto: deshabilitado en esta asistencia',
          RemoteControlAuthorization.suspended =>
            'Control remoto: suspendido hasta confirmar con el servidor',
          _ when !enabled => 'Control remoto: requiere habilitar accesibilidad',
          RemoteControlAuthorization.authorized => 'Control remoto: habilitado',
          RemoteControlAuthorization.pending =>
            'Control remoto: disponible cuando la asistencia esté activa',
        };
        final offerSettings =
            !enabled &&
            (authorization == RemoteControlAuthorization.authorized ||
                authorization == RemoteControlAuthorization.pending);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 4),
            Text(
              line,
              key: lineKey,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            if (offerSettings) ...[
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
