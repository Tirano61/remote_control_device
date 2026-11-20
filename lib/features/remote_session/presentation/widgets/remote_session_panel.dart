import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/widgets/failure_messages.dart';
import 'package:remote_control_device/features/remote_control/presentation/widgets/remote_control_status.dart';
import 'package:remote_control_device/features/remote_session/domain/entities/remote_session_ended_by.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_device/features/screen_capture/domain/entities/screen_capture_status.dart';
import 'package:remote_control_device/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

/// What the screen shows while a remote assistance session is live.
///
/// It renders a state the backend confirmed and offers one action of its own:
/// ending the assistance. The only other button belongs to
/// [RemoteControlStatus], and it only opens Android's settings.
///
/// Screen sharing is one discreet line and never the headline. It is a
/// separate fact from the assistance itself — a user who declined Android's
/// capture dialog still has a technician connected — and putting it where the
/// headline is would make a refused permission look like a broken session.
/// Android's own dialog and its persistent notification are what actually tell
/// the user their screen is being shared; this line only agrees with them.
///
/// It reads two states because the user's question spans both, and the two are
/// allowed to disagree for a moment:
///
/// ```text
/// RemoteSession   the backend row. CONNECTING until the technician reports
///                 the connection with POST /remote-sessions/:id/activate,
///                 then ACTIVE.
/// WebRTC          the peer connection. Reaches connected on its own, with the
///                 control channel open, a beat before the row moves.
/// ```
///
/// `ACTIVE` is the same fact as the WebRTC one, confirmed by the backend and
/// agreed by both ends, so it is the headline: *Asistencia en curso*. The local
/// reading then becomes the supporting line, *Conexión remota establecida* —
/// the two say one thing together instead of contradicting each other.
///
/// In the window before the row moves, the local reading is all there is, and
/// it is still preferred over the row: "connecting to the technician" is false
/// once the two ends have found each other, whatever the row has not yet said.
/// The button is untouched throughout — ending the assistance is available at
/// every moment of this.
///
/// The connection line is the other honest bit. If the socket is down the
/// session is *not* assumed to be over: the last state the backend gave stands,
/// and the user is told the tablet is reconnecting.
class RemoteSessionPanel extends StatelessWidget {
  const RemoteSessionPanel({required this.state, super.key});

  /// Keys the widget tests address, so a rename of user-facing text is not a
  /// test failure.
  static const Key closeButtonKey = Key('remote-session-close-button');
  static const Key screenCaptureLineKey = Key('remote-session-screen-line');

  final RemoteSessionLive state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final technician = state.session.technician?.name;
    final failure = state.lastFailure;

    return BlocBuilder<DeviceRealtimeBloc, DeviceRealtimeState>(
      builder: (context, realtime) {
        final connected = realtime is DeviceRealtimeConnected;

        return BlocBuilder<WebRtcSessionBloc, WebRtcSessionState>(
          builder: (context, webRtc) => _body(
            context,
            theme: theme,
            technician: technician,
            failure: failure,
            connected: connected,
            // Success at this stage is both halves at once: the peer connection
            // connected and the control channel open. Either alone is still
            // "connecting", because either alone could not carry a command once
            // there is one to carry. Screen capture is deliberately not part of
            // it, and is read separately below.
            established: webRtc.isRemoteConnectionEstablished,
            screenCapture: webRtc.screenCapture,
          ),
        );
      },
    );
  }

  Widget _body(
    BuildContext context, {
    required ThemeData theme,
    required String? technician,
    required Failure? failure,
    required bool connected,
    required bool established,
    required ScreenCaptureStatus screenCapture,
  }) {
    final detail = _detail(connected: connected, established: established);
    final connectedSince = _connectedSince(connected: connected);
    final screen = _screenLine(screenCapture, connected: connected);
    final authorization = _authorization(screenCapture);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Asistencia remota', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          _headline(connected: connected, established: established),
          style: theme.textTheme.headlineSmall,
        ),
        if (detail != null) ...[
          const SizedBox(height: 8),
          Text(detail, style: theme.textTheme.bodyMedium),
        ],
        if (connectedSince != null) ...[
          const SizedBox(height: 4),
          Text(
            'Conectado desde: $connectedSince',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
        if (screen != null) ...[
          const SizedBox(height: 4),
          Text(
            screen,
            key: screenCaptureLineKey,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
        // Shown while reconnecting too: "suspended" is exactly what the user
        // needs to know then. Never "habilitado" unless the session is ACTIVE
        // and confirmed with the backend.
        RemoteControlStatus(authorization: authorization),
        if (technician != null) ...[
          const SizedBox(height: 8),
          Text(
            technician,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
        if (failure != null) _Note(FailureMessages.forRemoteSession(failure)),
        const SizedBox(height: 24),
        OutlinedButton(
          key: closeButtonKey,
          // Always available, the network included: pressing it ends the
          // assistance on this tablet at once, whether or not the backend can
          // be told. A working peer connection does not take it away either —
          // that is precisely when ending the assistance matters most. The
          // panel is replaced the moment it is pressed, which is also what
          // makes a second press impossible.
          onPressed: () => context.read<RemoteSessionBloc>().add(
            const RemoteSessionCloseRequested(),
          ),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('FINALIZAR ASISTENCIA'),
          ),
        ),
      ],
    );
  }

  /// The one line that tells the user what is happening, in this order of
  /// precedence: a connection they have lost, and then what the assistance
  /// actually is. Their own FINALIZAR is not on the list: it replaces this
  /// panel with [RemoteSessionEndedPanel].
  ///
  /// That last part is the whole change `ACTIVE` brings. The backend now writes
  /// it when the technician reports the connection, so the row is no longer
  /// permanently behind the peer connection and there is no reason to talk
  /// around it: `ACTIVE` is the state both ends and the backend agree on, and
  /// it is what the user is told.
  ///
  /// [established] still decides the `CONNECTING` line, because there is a real
  /// window — the peer connection comes up, and the technician's `/activate`
  /// and its event follow — in which the local reading is the only one there
  /// is. Saying "connecting to the technician" then would be false.
  String _headline({required bool connected, required bool established}) {
    if (!connected) return 'Reconectando...';
    // Back, but the backend has not yet confirmed the session is still
    // authorised. Nothing runs until it does.
    if (state.isSuspended) return 'Verificando la asistencia...';

    return switch (state) {
      RemoteSessionActive() => 'Asistencia en curso',
      RemoteSessionConnecting() =>
        established
            ? 'Conexión remota establecida'
            : 'Conectando con el técnico...',
    };
  }

  /// The supporting line under the headline, or `null`.
  ///
  /// Only one thing is ever said here, and only while the headline is
  /// `Asistencia en curso`: that the link this tablet holds is up. Under any
  /// other headline it would either repeat it — the `CONNECTING` case already
  /// says exactly this — or contradict it, which is what the "reconnecting"
  /// case is protected from by [_headline] having returned first.
  String? _detail({required bool connected, required bool established}) {
    if (!connected) return null;
    if (state.isSuspended) return null;
    if (state is! RemoteSessionActive) return null;

    return established ? 'Conexión remota establecida' : null;
  }

  /// One short line about the screen, or `null` when there is nothing to say.
  ///
  /// Four outcomes, no technical detail and no button. The permission dialog
  /// belongs to Android, the "stop sharing" control belongs to Android, and
  /// duplicating either here would offer the user a second way to do something
  /// the system already does better.
  ///
  /// Nothing is shown while the tablet is reconnecting: the headline is
  /// already saying the connection is the problem, and a capture that is still
  /// running locally is not what the user needs to read at that moment.
  ///
  /// Back online but not confirmed yet, a running capture is not "compartiendo"
  /// either: nothing it captures reaches the technician until the backend
  /// confirms the session (`WebRtcSessionBloc` holds the frames back).
  String? _screenLine(ScreenCaptureStatus status, {required bool connected}) {
    // Android taking the screen away is said whatever the connection: it is
    // the reason control is gone, and it does not depend on the socket.
    if (status == ScreenCaptureStatus.stoppedBySystem) {
      return 'Pantalla: Android detuvo la captura';
    }
    if (!connected) return null;
    if (state.isSuspended && status == ScreenCaptureStatus.active) {
      return 'Pantalla: en pausa hasta confirmar con el servidor';
    }

    return switch (status) {
      ScreenCaptureStatus.idle => null,
      ScreenCaptureStatus.requesting => 'Pantalla: esperando autorización',
      ScreenCaptureStatus.active => 'Pantalla: compartiendo',
      ScreenCaptureStatus.denied => 'Pantalla: permiso rechazado',
      ScreenCaptureStatus.failed => 'Pantalla: error al compartir',
      ScreenCaptureStatus.stoppedBySystem => null,
    };
  }

  /// What the remote-control line may claim. Built from the session and the
  /// screen, never from the accessibility service.
  RemoteControlAuthorization _authorization(ScreenCaptureStatus screen) {
    if (screen == ScreenCaptureStatus.stoppedBySystem) {
      return RemoteControlAuthorization.revoked;
    }
    if (state.isSuspended) return RemoteControlAuthorization.suspended;
    return switch (state) {
      RemoteSessionActive() => RemoteControlAuthorization.authorized,
      RemoteSessionConnecting() => RemoteControlAuthorization.pending,
    };
  }

  /// `HH:mm` of `connectedAt`, in the tablet's local time, or `null`.
  ///
  /// Shown only for an `ACTIVE` session, because only an activated one has the
  /// field at all. The instant comes from the backend and is merely rendered
  /// here: nothing measures elapsed time, and nothing is filled in when the
  /// field is absent.
  String? _connectedSince({required bool connected}) {
    if (!connected || state.isSuspended) return null;
    if (state is! RemoteSessionActive) return null;

    final connectedAt = state.session.connectedAt?.toLocal();
    if (connectedAt == null) return null;

    final hour = connectedAt.hour.toString().padLeft(2, '0');
    final minute = connectedAt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
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

/// What the screen shows once the user has pressed `FINALIZAR ASISTENCIA`.
///
/// The assistance is over on this tablet from that press: the technician can
/// no longer act on it, the peer connection is closed and the screen is no
/// longer captured. That is said plainly and first. What may still be open is
/// only whether the *server* has recorded it, and that is said separately and
/// honestly — the screen never claims the backend closed a session it did not
/// confirm, and never suggests the screen is still being shared.
///
/// There is no screen line, no remote-control status and no FINALIZAR button
/// here: there is nothing left to share, to control or to end. The one action,
/// REINTENTAR, only tells the server again; it cannot resume anything.
class RemoteSessionEndedPanel extends StatelessWidget {
  const RemoteSessionEndedPanel({required this.state, super.key});

  static const Key retryButtonKey = Key('remote-session-ended-retry-button');

  /// The sentence shown when the server could not confirm the close.
  static const String unconfirmedMessage =
      'La asistencia terminó en esta tablet, pero no se pudo confirmar el '
      'cierre con el servidor.';

  /// The sentence shown when the tablet ended the assistance itself because it
  /// could not confirm it with the server in time.
  static const String authorityLostMessage =
      'Se perdió la conexión con el servidor y la asistencia se detuvo por '
      'seguridad.';

  /// The line shown under [authorityLostMessage]. Nothing is sent for such an
  /// end — the server closes the assistance by itself — so there is no
  /// REINTENTAR, only what the user can expect next.
  static const String authorityLostNextStep =
      'Podrás solicitar una nueva asistencia cuando el servidor registre el '
      'cierre.';

  final RemoteSessionEndedLocally state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lostAuthority =
        state.reason == RemoteSessionLocalEndReason.authorityLost;
    if (lostAuthority) return _buildAuthorityLost(theme);
    final unconfirmed = !state.confirming && state.lastFailure != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Asistencia remota', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          state.confirming
              ? 'Finalizando la asistencia...'
              : 'Asistencia finalizada',
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          'El técnico ya no puede controlar esta tablet ni ver su pantalla.',
          style: theme.textTheme.bodyMedium,
        ),
        if (unconfirmed)
          const _Note(unconfirmedMessage)
        else if (!state.confirming) ...[
          const SizedBox(height: 4),
          Text(
            'Confirmando el cierre con el servidor...',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
        if (unconfirmed) ...[
          const SizedBox(height: 12),
          OutlinedButton(
            key: retryButtonKey,
            onPressed: () => context.read<RemoteSessionBloc>().add(
              const RemoteSessionCloseRequested(),
            ),
            child: const Text('REINTENTAR'),
          ),
        ],
      ],
    );
  }

  /// The tablet stopped the assistance because it could not confirm it with
  /// the server in time. Says it was the connection, not anybody's FINALIZAR,
  /// and offers no action: nothing is owed to the server.
  Widget _buildAuthorityLost(ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Asistencia remota', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      Text('Asistencia interrumpida', style: theme.textTheme.headlineSmall),
      const SizedBox(height: 8),
      Text(authorityLostMessage, style: theme.textTheme.bodyMedium),
      const SizedBox(height: 8),
      Text(
        'El técnico ya no puede controlar esta tablet ni ver su pantalla.',
        style: theme.textTheme.bodyMedium,
      ),
      const SizedBox(height: 4),
      Text(
        authorityLostNextStep,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
    ],
  );
}

/// What the screen shows the moment the backend says it closed the session —
/// the technician did, or the backend did on its own — while the tablet checks
/// what comes next.
///
/// Like [RemoteSessionEndedPanel], it says first that the technician can no
/// longer act on the tablet or see it: control, the peer connection and the
/// capture were let go when the notice arrived, not when this was drawn.
class RemoteSessionClosedRemotelyPanel extends StatelessWidget {
  const RemoteSessionClosedRemotelyPanel({required this.state, super.key});

  final RemoteSessionClosedRemotely state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failure = state.lastFailure;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Asistencia remota', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text('Asistencia finalizada', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          RemoteSessionClosureNote.messageFor(state.endedBy),
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'El técnico ya no puede controlar esta tablet ni ver su pantalla.',
          style: theme.textTheme.bodyMedium,
        ),
        if (failure != null) _Note(FailureMessages.forRemoteSession(failure)),
      ],
    );
  }
}

/// One line above the support request saying who closed the last assistance,
/// when it was not the user here — or, with [RemoteSessionClosureNote.interrupted],
/// that it ended during a loss of connection.
class RemoteSessionClosureNote extends StatelessWidget {
  const RemoteSessionClosureNote({
    required RemoteSessionEndedBy this.endedBy,
    super.key,
  });

  const RemoteSessionClosureNote.interrupted({super.key}) : endedBy = null;

  static const Key noteKey = Key('remote-session-closure-note');

  /// `null` for an interrupted assistance.
  final RemoteSessionEndedBy? endedBy;

  /// Shown instead when the last assistance ended during a loss of connection
  /// and nobody said who closed it ([RemoteSessionIdle.interrupted]).
  ///
  /// "durante", not "por": a session found gone by a read made while the
  /// tablet was suspended may have been closed by the technician (seen on the
  /// T10A, Prompt 38) as much as by the backend's SYSTEM close. The sentence
  /// is true either way, and never suggests a FINALIZAR on this tablet.
  static const String interruptedMessage =
      'La asistencia anterior terminó durante una pérdida de conexión con el '
      'servidor.';

  static String messageFor(RemoteSessionEndedBy endedBy) => switch (endedBy) {
    RemoteSessionEndedBy.technician => 'El técnico finalizó la asistencia.',
    RemoteSessionEndedBy.system =>
      'El servidor cerró la asistencia porque se perdió la conexión.',
    RemoteSessionEndedBy.device || RemoteSessionEndedBy.unknown =>
      'La asistencia fue cerrada por el servidor.',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        switch (endedBy) {
          final endedBy? => messageFor(endedBy),
          null => interruptedMessage,
        },
        key: noteKey,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.outline,
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
