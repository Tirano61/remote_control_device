import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/features/device/presentation/bloc/realtime/device_realtime_bloc.dart';
import 'package:remote_control_device/features/device/presentation/widgets/failure_messages.dart';
import 'package:remote_control_device/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_device/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

/// What the screen shows while a remote assistance session is live.
///
/// It renders a state the backend confirmed and offers exactly one action:
/// ending the assistance. There is still no video and no remote control — this
/// build negotiates a peer connection and a control channel and sends nothing
/// over either — so the panel says "remote connection established" and never
/// "sharing your screen", which would be a promise the application cannot keep.
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
            // there is one to carry.
            established: webRtc.isRemoteConnectionEstablished,
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
  }) {
    final detail = _detail(connected: connected, established: established);
    final connectedSince = _connectedSince(connected: connected);

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
          // Disabled only while the close itself is in flight. A tablet that
          // lost the network may still try: the request either reaches the
          // backend or fails and can be repeated, and taking the button away
          // would leave the user unable to end an assistance they no longer
          // want. A working peer connection does not take it away either —
          // that is precisely when ending the assistance matters most.
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
  }

  /// The one line that tells the user what is happening, in this order of
  /// precedence: an action of their own, a connection they have lost, and then
  /// what the assistance actually is.
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
    if (state.closing) return 'Finalizando la asistencia...';
    if (!connected) return 'Reconectando...';

    return switch (state) {
      // Deliberately not "sharing your screen": nothing is captured and nothing
      // is controlled in this build.
      RemoteSessionActive() => 'Asistencia en curso',
      RemoteSessionConnecting() => established
          ? 'Conexión remota establecida'
          : 'Conectando con el técnico...',
    };
  }

  /// The supporting line under the headline, or `null`.
  ///
  /// Only one thing is ever said here, and only while the headline is
  /// `Asistencia en curso`: that the link this tablet holds is up. Under any
  /// other headline it would either repeat it — the `CONNECTING` case already
  /// says exactly this — or contradict it, which is what the "reconnecting" and
  /// "finishing" cases are protected from by [_headline] having returned first.
  String? _detail({required bool connected, required bool established}) {
    if (state.closing || !connected) return null;
    if (state is! RemoteSessionActive) return null;

    return established ? 'Conexión remota establecida' : null;
  }

  /// `HH:mm` of `connectedAt`, in the tablet's local time, or `null`.
  ///
  /// Shown only for an `ACTIVE` session, because only an activated one has the
  /// field at all. The instant comes from the backend and is merely rendered
  /// here: nothing measures elapsed time, and nothing is filled in when the
  /// field is absent.
  String? _connectedSince({required bool connected}) {
    if (state.closing || !connected) return null;
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
