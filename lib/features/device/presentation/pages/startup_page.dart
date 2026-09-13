import 'package:flutter/material.dart';

/// Shown while the startup sequence runs (reading secure storage, logging in,
/// validating with the backend).
class StartupPage extends StatelessWidget {
  const StartupPage({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'ASISTENCIA REMOTA',
              style: theme.textTheme.titleMedium?.copyWith(letterSpacing: 2),
            ),
            const SizedBox(height: 32),
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(message, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
