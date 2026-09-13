part of 'enrollment_bloc.dart';

sealed class EnrollmentEvent extends Equatable {
  const EnrollmentEvent();

  @override
  List<Object?> get props => [];
}

/// The user submitted the activation form.
final class EnrollmentSubmitted extends EnrollmentEvent {
  const EnrollmentSubmitted({required this.publicId, required this.code});

  final String publicId;
  final String code;

  @override
  List<Object?> get props => [publicId, code];
}
