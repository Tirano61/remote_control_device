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
/// allowed to disagree:
///
/// ```text
/// RemoteSession   the backend row. Stays CONNECTING; the current backend has
///                 no transition to ACTIVE at all.
/// WebRTC          the peer connection. Reaches connected on its own, with the
///                 control channel open, while the row above has not moved.
/// ```
///
/// So the headline prefers the WebRTC fact once it holds. "Connecting to the
/// technician" is true until the two ends have actually found each other and
/// false afterwards, whatever the row still says. The button is untouched
/// either way — ending the assistance is available at every moment of this.
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Asistencia remota', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          _headline(connected: connected, established: established),
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
  /// precedence: an action of their own, a connection they have lost, the peer
  /// connection actually being up, and only then the status the backend
  /// reported.
  ///
  /// The third of those is why [established] exists. The backend leaves the
  /// session at `CONNECTING` — no path moves it to `ACTIVE` — so a tablet that
  /// waited for the row would say "connecting to the technician" for the whole
  /// of a working session. What the user is being told here is whether the two
  /// ends found each other, which is a fact this application holds and the row
  /// does not.
  String _headline({required bool connected, required bool established}) {
    if (state.closing) return 'Finalizando la asistencia...';
    if (!connected) return 'Reconectando...';
    // Deliberately not "sharing your screen": nothing is captured and nothing
    // is controlled in this build. The link exists; that is the whole claim.
    if (established) return 'Conexión remota establecida';

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
