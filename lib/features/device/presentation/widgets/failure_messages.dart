import 'package:remote_control_device/core/error/failures.dart';

/// Maps failure *types* — never backend message strings — to text the operator
/// can act on. Raw exceptions, stack traces and backend internals never reach
/// the screen.
abstract final class FailureMessages {
  /// Same failure type means different things in different flows, so the
  /// enrollment form and the startup sequence get their own wording.
  static String forEnrollment(Failure failure) => switch (failure) {
    AuthFailure() =>
      'El identificador o el código no son válidos, o el código ya expiró. '
          'Solicitá un código nuevo al técnico.',
    ValidationFailure() =>
      'Revisá los datos ingresados: el identificador debe tener el formato '
          '384-729-142 y el código 6 dígitos.',
    NetworkFailure() =>
      'No se pudo contactar al servidor. Verificá la conexión e intentá de nuevo.',
    StorageFailure() =>
      'No se pudo guardar la activación en este dispositivo. Intentá de nuevo.',
    ServerFailure() => 'El servidor no pudo procesar la activación. Intentá más tarde.',
  };

  static String forStartup(Failure failure) => switch (failure) {
    NetworkFailure() =>
      'No hay conexión con el servidor. El dispositivo sigue activado; '
          'se puede reintentar.',
    StorageFailure() =>
      'No se pudieron leer los datos de activación de este dispositivo.',
    ServerFailure() => 'El servidor respondió con un error. Intentá de nuevo.',
    ValidationFailure() => 'El servidor rechazó la solicitud. Intentá de nuevo.',
    AuthFailure() => 'El dispositivo debe volver a activarse.',
  };
}
