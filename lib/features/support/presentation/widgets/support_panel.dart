import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/widgets/failure_messages.dart';
import 'package:remote_control_device/features/support/domain/entities/support_request.dart';
import 'package:remote_control_device/features/support/presentation/bloc/support/support_bloc.dart';

/// The assistance half of the operational screen.
///
/// Every branch renders a state the backend confirmed. The one decision taken
/// locally is whether the *request* button may be pressed: the backend only
/// lets a technician take a request from a device it sees as `ONLINE`, and
/// presence is the Socket.IO connection, so asking for help while the channel
/// is down would produce a request nobody could answer.
class SupportPanel extends StatelessWidget {
  const SupportPanel({super.key});

  /// Keys the widget tests address, so a rename of user-facing text is not a
  /// test failure.
  static const Key requestButtonKey = Key('support-request-button');
  static const Key cancelButtonKey = Key('support-cancel-button');
  static const Key acceptButtonKey = Key('support-accept-button');
  static const Key rejectButtonKey = Key('support-reject-button');
  static const Key retryButtonKey = Key('support-retry-button');
  static const Key controlDisclosureKey = Key('support-control-disclosure');

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SupportBloc, SupportState>(
      builder: (context, state) => switch (state) {
        SupportInitial() || SupportLoading() => const _Busy(
          message: 'Consultando el estado...',
        ),
        SupportIdle(:final lastFailure) => _IdlePanel(failure: lastFailure),
        SupportCreating() => const _Busy(message: 'Enviando solicitud...'),
        SupportWaiting(:final busy, :final lastFailure) => _WaitingPanel(
          busy: busy,
          failure: lastFailure,
        ),
        SupportAssigned(
          :final request,
          :final busy,
          :final lastFailure,
        ) => _AssignedPanel(
          request: request,
          busy: busy,
          failure: lastFailure,
        ),
        SupportAccepted(
          :final request,
          :final busy,
          :final lastFailure,
        ) => _AcceptedPanel(
          request: request,
          busy: busy,
          failure: lastFailure,
        ),
        SupportUnavailable(:final failure) => _UnavailablePanel(
          failure: failure,
        ),
      },
    );
  }
}

/// No request: offer to create one, but only while the device is reachable.
class _IdlePanel extends StatelessWidget {
  const _IdlePanel({this.failure});

  final Failure? failure;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DeviceRealtimeBloc, DeviceRealtimeState>(
      builder: (context, realtime) {
        final connected = realtime is DeviceRealtimeConnected;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (failure != null) _Note(FailureMessages.forSupport(failure!)),
            FilledButton(
              key: SupportPanel.requestButtonKey,
              onPressed: connected
                  ? () =>
                        context.read<SupportBloc>().add(const SupportRequested())
                  : null,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('SOLICITAR ASISTENCIA'),
              ),
            ),
            if (!connected) ...[
              const SizedBox(height: 12),
              const _Note(
                'Conectando al servicio... podrás pedir asistencia en cuanto '
                'el dispositivo esté conectado.',
              ),
            ],
          ],
        );
      },
    );
  }
}

/// `WAITING`: sent, nobody has taken it. Withdrawing is the only action.
class _WaitingPanel extends StatelessWidget {
  const _WaitingPanel({required this.busy, this.failure});

  final bool busy;
  final Failure? failure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Solicitud enviada', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          'Esperando a un técnico...',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        if (failure != null) _Note(FailureMessages.forSupport(failure!)),
        const SizedBox(height: 20),
        OutlinedButton(
          key: SupportPanel.cancelButtonKey,
          onPressed: busy
              ? null
              : () =>
                    context.read<SupportBloc>().add(const SupportCancelRequested()),
          child: const Text('CANCELAR SOLICITUD'),
        ),
      ],
    );
  }
}

/// `ASSIGNED`: the consent prompt. Both answers are explicit presses; nothing
/// here happens on its own, and no timer decides for the user.
class _AssignedPanel extends StatelessWidget {
  const _AssignedPanel({
    required this.request,
    required this.busy,
    this.failure,
  });

  final SupportRequest request;
  final bool busy;
  final Failure? failure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bloc = context.read<SupportBloc>();
    // The contract gives the device the technician's name and nothing else. A
    // request that arrived without the block still has to be answerable.
    final who = request.technician?.name ?? 'Un técnico';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Asistencia técnica', style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        Text(
          '$who quiere atender su solicitud.',
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        const _ControlDisclosure(key: SupportPanel.controlDisclosureKey),
        const SizedBox(height: 16),
        Text('¿Desea permitir la asistencia?', style: theme.textTheme.bodyLarge),
        if (failure != null) _Note(FailureMessages.forSupport(failure!)),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: SupportPanel.rejectButtonKey,
                onPressed: busy
                    ? null
                    : () => bloc.add(const SupportRejectRequested()),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('RECHAZAR'),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: FilledButton(
                key: SupportPanel.acceptButtonKey,
                onPressed: busy
                    ? null
                    : () => bloc.add(const SupportAcceptRequested()),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('PERMITIR'),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// What pressing `PERMITIR` allows, for this assistance only.
///
/// Android does not ask again when an update widens the accessibility service,
/// so this is where the user learns about text input. It has to stay true of
/// what the code does: the field is whichever one has focus, which the
/// technician can also move with a tap; the text replaces what was there; and
/// the shared picture shows whatever a field displays.
class _ControlDisclosure extends StatelessWidget {
  const _ControlDisclosure({super.key});

  static const List<String> _abilities = [
    'Ver la pantalla que se comparta.',
    'Tocar y deslizar sobre la pantalla.',
    'Usar Atrás, Inicio y Recientes.',
    'Introducir texto en el campo que esté seleccionado, reemplazando su '
        'contenido.',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Durante esta asistencia, el técnico podrá:',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        for (final ability in _abilities)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: theme.textTheme.bodyMedium),
                Expanded(
                  child: Text(ability, style: theme.textTheme.bodyMedium),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Text(
          'Aparte de lo que se vea en la pantalla compartida, el sistema no '
          'envía al técnico el contenido actual de sus campos de texto. No lee '
          'las ventanas de forma continua ni las supervisa fuera de una '
          'asistencia activa.',
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }
}

/// `ACCEPTED`: authorised, nothing started. The technician still has to create
/// the remote session, which this build neither creates nor joins.
class _AcceptedPanel extends StatelessWidget {
  const _AcceptedPanel({
    required this.request,
    required this.busy,
    this.failure,
  });

  final SupportRequest request;
  final bool busy;
  final Failure? failure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final who = request.technician?.name;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Técnico autorizado', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (who != null) ...[
          Text(who, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
        ],
        Text(
          'Preparando la asistencia...',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        if (failure != null) _Note(FailureMessages.forSupport(failure!)),
        const SizedBox(height: 20),
        // The backend still allows withdrawing while no remote session exists.
        // If one has started it answers 409, and the state is simply re-read.
        OutlinedButton(
          key: SupportPanel.cancelButtonKey,
          onPressed: busy
              ? null
              : () =>
                    context.read<SupportBloc>().add(const SupportCancelRequested()),
          child: const Text('CANCELAR'),
        ),
      ],
    );
  }
}

/// The backend could not be asked. Distinct from "no request": the user is told
/// the state is unknown rather than being offered an action based on a guess.
class _UnavailablePanel extends StatelessWidget {
  const _UnavailablePanel({required this.failure});

  final Failure failure;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Note(FailureMessages.forSupport(failure)),
        const SizedBox(height: 12),
        OutlinedButton(
          key: SupportPanel.retryButtonKey,
          onPressed: () =>
              context.read<SupportBloc>().add(const SupportSyncRequested()),
          child: const Text('REINTENTAR'),
        ),
      ],
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          height: 18,
          width: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Flexible(child: Text(message, style: theme.textTheme.bodyMedium)),
      ],
    );
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
