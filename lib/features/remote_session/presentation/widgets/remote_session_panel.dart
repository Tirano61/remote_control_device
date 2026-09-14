import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/widgets/failure_messages.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';

/// What the screen shows while a remote assistance session is live.
///
/// It renders a state the backend confirmed and offers exactly one action:
/// ending the assistance. There is no video and no remote control yet — this
/// build negotiates nothing — so the panel deliberately says "connecting" and
/// "in progress" and never "sharing your screen", which would be a promise the
/// application cannot keep.
///
/// The connection line is the other honest bit. If the socket is down the
/// session is *not* assumed to be over: the last state the backend gave stands,
/// and the user is told the tablet is reconnecting.
class RemoteSessionPanel extends StatelessWidget {
  const RemoteSessionPanel({required this.state, super.key});

  /// Keys the widget tests address, so a rename of user-facing text is not a
  /// test failure.
  static const Key closeButtonKey = Key('remote-session-close-button');

  final RemoteSessionLive state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final technician = state.session.technician?.name;
    final failure = state.lastFailure;

    return BlocBuilder<DeviceRealtimeBloc, DeviceRealtimeState>(
      builder: (context, realtime) {
        final connected = realtime is DeviceRealtimeConnected;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Asistencia remota', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              _headline(connected: connected),
              style: theme.textTheme.headlineSmall,
            ),
            if (technician != null) ...[
              const SizedBox(height: 8),
              Text(
                technician,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
            if (failure != null)
              _Note(FailureMessages.forRemoteSession(failure)),
            const SizedBox(height: 24),
            OutlinedButton(
              key: closeButtonKey,
              // Disabled only while the close itself is in flight. A tablet
              // that lost the network may still try: the request either
              // reaches the backend or fails and can be repeated, and taking
              // the button away would leave the user unable to end an
              // assistance they no longer want.
              onPressed: state.closing
                  ? null
                  : () => context.read<RemoteSessionBloc>().add(
                      const RemoteSessionCloseRequested(),
                    ),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('FINALIZAR ASISTENCIA'),
              ),
            ),
          ],
        );
      },
    );
  }

  /// The one line that tells the user what is happening, in this order of
  /// precedence: an action of their own, a connection they have lost, and only
  /// then the status the backend reported.
  String _headline({required bool connected}) {
    if (state.closing) return 'Finalizando la asistencia...';
    if (!connected) return 'Reconectando...';

    return switch (state) {
      RemoteSessionConnecting() => 'Conectando con el técnico...',
      // Reserved by the contract and not written by any backend path today.
      // Shown without claiming that a screen is being shared or controlled.
      RemoteSessionActive() => 'Asistencia en curso',
    };
  }
}

/// Short explanatory line. Always built from a failure *type*, never from a
/// backend message.
class _Note extends StatelessWidget {
  const _Note(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        message,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }
}

/// The backend could not be asked whether an assistance session exists.
///
/// Shown instead of the support panel, and deliberately so: while this is on
/// screen it is unknown whether a technician is connected, and offering
/// "request assistance" would be answering a question nobody answered. "There
/// is no session" and "I could not find out" must never look the same.
class RemoteSessionUnavailablePanel extends StatelessWidget {
  const RemoteSessionUnavailablePanel({required this.failure, super.key});

  static const Key retryButtonKey = Key('remote-session-retry-button');

  final Failure failure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'No se pudo comprobar el estado de la asistencia.',
          style: theme.textTheme.bodyMedium,
        ),
        _Note(FailureMessages.forRemoteSession(failure)),
        const SizedBox(height: 12),
        OutlinedButton(
          key: retryButtonKey,
          onPressed: () => context.read<RemoteSessionBloc>().add(
            const RemoteSessionSyncRequested(),
          ),
          child: const Text('REINTENTAR'),
        ),
      ],
    );
  }
}
