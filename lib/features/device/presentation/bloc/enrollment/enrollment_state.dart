part of 'enrollment_bloc.dart';

sealed class EnrollmentState extends Equatable {
  const EnrollmentState();

  @override
  List<Object?> get props => [];
}

final class EnrollmentInitial extends EnrollmentState {
  const EnrollmentInitial();
}

final class EnrollmentSubmitting extends EnrollmentState {
  const EnrollmentSubmitting();
}

/// Activation succeeded and the credential is already in secure storage.
///
/// Only non-sensitive fields are carried: the `deviceSecret` never reaches
/// bloc state, and therefore never reaches a widget.
final class EnrollmentSuccess extends EnrollmentState {
  const EnrollmentSuccess({required this.publicId, required this.name});

  final String publicId;
  final String name;

  @override
  List<Object?> get props => [publicId, name];
}

final class EnrollmentFailure extends EnrollmentState {
  const EnrollmentFailure(this.failure);

  final Failure failure;

  @override
  List<Object?> get props => [failure];
}
