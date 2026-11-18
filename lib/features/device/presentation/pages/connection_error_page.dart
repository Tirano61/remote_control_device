import 'package:flutter/material.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/features/device/presentation/widgets/failure_messages.dart';

/// Authentication could not be confirmed, for a reason that is not a refused
/// credential: no network, a server error, or an answer that confirms nothing
/// (a redirect, a `401` from something in front of the backend). The
/// enrollment is intact and the device is not authorised; the session retries
/// on its own on a bounded backoff, and this screen offers to retry now.
class ConnectionErrorPage extends StatelessWidget {
  const ConnectionErrorPage({
    required this.failure,
    required this.onRetry,
    super.key,
  });

  final Failure failure;
  final VoidCallback onRetry;

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
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.cloud_off_outlined,
                    size: 56,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Autenticación no disponible',
                    style: theme.textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    FailureMessages.forStartup(failure),
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Se reintentará automáticamente.',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reintentar'),
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
