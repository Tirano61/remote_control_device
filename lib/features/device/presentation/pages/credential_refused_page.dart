import 'package:flutter/material.dart';

/// The backend refused this device's credential (`401
/// DEVICE_CREDENTIAL_REJECTED`).
///
/// Nothing on this screen is authorised: no Device JWT is held, the realtime
/// channel is closed and assistance cannot be requested. The credential is
/// still in secure storage, because the refusal does not say whether the device
/// was deactivated for a while or needs a new activation — so both ways out are
/// offered, and neither is taken automatically.
class CredentialRefusedPage extends StatelessWidget {
  const CredentialRefusedPage({
    required this.onRetry,
    required this.onReEnroll,
    super.key,
  });

  final VoidCallback onRetry;
  final VoidCallback onReEnroll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.gpp_bad_outlined,
                    size: 56,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Autenticación rechazada',
                    style: theme.textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'El servidor rechazó la credencial de este dispositivo. '
                    'Puede estar desactivado temporalmente o necesitar una '
                    'activación nueva.',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'La asistencia remota no está disponible. La activación '
                    'guardada se conserva: si el técnico reactiva el '
                    'dispositivo, alcanza con reintentar.',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reintentar'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: onReEnroll,
                    child: const Text('Activar de nuevo'),
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
