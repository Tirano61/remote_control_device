import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:remote_control_device/core/error/failures.dart';
import 'package:remote_control_device/core/result/result.dart';
import 'package:remote_control_device/features/device/domain/entities/device_activation.dart';
import 'package:remote_control_device/features/device/domain/usecases/enroll_device.dart';

part 'enrollment_event.dart';
part 'enrollment_state.dart';

/// Drives `publicId` + 6-digit code → `POST /device-enrollment/activate` →
/// credential stored in secure storage.
///
/// The form only submits; the backend remains authoritative over whether the
/// pair is valid.
class EnrollmentBloc extends Bloc<EnrollmentEvent, EnrollmentState> {
  EnrollmentBloc({required EnrollDevice enrollDevice})
    : _enrollDevice = enrollDevice,
      super(const EnrollmentInitial()) {
    on<EnrollmentSubmitted>(_onSubmitted);
  }

  final EnrollDevice _enrollDevice;

  Future<void> _onSubmitted(
    EnrollmentSubmitted event,
    Emitter<EnrollmentState> emit,
  ) async {
    if (state is EnrollmentSubmitting) return;

    emit(const EnrollmentSubmitting());

    final result = await _enrollDevice(
      publicId: event.publicId.trim(),
      code: event.code.trim(),
    );

    switch (result) {
      case Ok<DeviceActivation>(:final value):
        emit(EnrollmentSuccess(publicId: value.publicId, name: value.name));
      case Err<DeviceActivation>(:final failure):
        emit(EnrollmentFailure(failure));
    }
  }
}
