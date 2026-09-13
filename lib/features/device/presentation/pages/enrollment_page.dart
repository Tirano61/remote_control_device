import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/enrollment/enrollment_bloc.dart';
import 'package:remote_control_device/features/device/presentation/bloc/session/device_session_bloc.dart';
import 'package:remote_control_device/features/device/presentation/widgets/failure_messages.dart';
import 'package:remote_control_device/features/device/presentation/widgets/public_id_input_formatter.dart';

/// Activation form: `publicId` + the 6-digit code the technician reads out.
///
/// The widget only collects input and dispatches an event; the HTTP call, the
/// secure write and the error mapping all happen below the presentation layer.
class EnrollmentPage extends StatefulWidget {
  const EnrollmentPage({this.reEnrollmentRequired = false, super.key});

  /// `true` when a previously working credential was rejected by the backend.
  final bool reEnrollmentRequired;

  @override
  State<EnrollmentPage> createState() => _EnrollmentPageState();
}

class _EnrollmentPageState extends State<EnrollmentPage> {
  static const int _codeLength = 6;

  final _formKey = GlobalKey<FormState>();
  final _publicIdController = TextEditingController();
  final _codeController = TextEditingController();

  @override
  void dispose() {
    _publicIdController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    context.read<EnrollmentBloc>().add(
      EnrollmentSubmitted(
        publicId: _publicIdController.text,
        code: _codeController.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BlocConsumer<EnrollmentBloc, EnrollmentState>(
      listener: (context, state) {
        if (state is EnrollmentSuccess) {
          // Credentials are already stored; hand control back to the
          // application-wide session bloc, which logs in and validates.
          context.read<DeviceSessionBloc>().add(
            const DeviceSessionEnrollmentCompleted(),
          );
        }
      },
      builder: (context, state) {
        final isSubmitting = state is EnrollmentSubmitting;

        return Scaffold(
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'ASISTENCIA REMOTA',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium?.copyWith(
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(height: 32),
                        Text(
                          'Activar dispositivo',
                          style: theme.textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          widget.reEnrollmentRequired
                              ? 'Este dispositivo debe volver a activarse. '
                                    'Pedile al técnico un código de activación nuevo.'
                              : 'Ingresá el identificador del dispositivo y el '
                                    'código de 6 dígitos que te indique el técnico.',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 32),
                        TextFormField(
                          controller: _publicIdController,
                          enabled: !isSubmitting,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.next,
                          inputFormatters: const [PublicIdInputFormatter()],
                          decoration: const InputDecoration(
                            labelText: 'Identificador del dispositivo',
                            hintText: '384-729-142',
                            border: OutlineInputBorder(),
                          ),
                          validator: _validatePublicId,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _codeController,
                          enabled: !isSubmitting,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.done,
                          maxLength: _codeLength,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(_codeLength),
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Código de activación',
                            hintText: '000000',
                            border: OutlineInputBorder(),
                          ),
                          validator: _validateCode,
                          onFieldSubmitted: (_) => _submit(),
                        ),
                        const SizedBox(height: 8),
                        if (state is EnrollmentFailure)
                          _ErrorBanner(
                            message: FailureMessages.forEnrollment(state.failure),
                          ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: isSubmitting ? null : _submit,
                          child: isSubmitting
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Activar'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String? _validatePublicId(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Ingresá el identificador del dispositivo.';
    if (!RegExp(r'^\d{3}-\d{3}-\d{3}$').hasMatch(text)) {
      return 'El formato debe ser 384-729-142.';
    }
    return null;
  }

  String? _validateCode(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Ingresá el código de activación.';
    if (!RegExp(r'^\d{6}$').hasMatch(text)) {
      return 'El código tiene 6 dígitos.';
    }
    return null;
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onErrorContainer,
        ),
      ),
    );
  }
}
