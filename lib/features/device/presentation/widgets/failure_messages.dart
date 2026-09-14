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
    NotFoundFailure() =>
      'El identificador no corresponde a ningún dispositivo registrado.',
    ConflictFailure() =>
      'Este dispositivo ya fue activado. Solicitá un código nuevo al técnico.',
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
    NotFoundFailure() || ConflictFailure() =>
      'El servidor respondió de forma inesperada. Intentá de nuevo.',
  };

  /// Remote session. Wording is deliberately calmer than the support one: at
  /// this point a technician is on the other end, so a failed call is a hiccup
  /// in an ongoing conversation rather than a request that went nowhere.
  static String forRemoteSession(Failure failure) => switch (failure) {
    NetworkFailure() =>
      'Se perdió la conexión con el servidor. Reintentando...',
    ConflictFailure() || NotFoundFailure() =>
      'La asistencia cambió de estado. Se actualizó la información.',
    AuthFailure() => 'El dispositivo debe volver a activarse.',
    ValidationFailure() => 'El servidor rechazó la solicitud.',
    StorageFailure() =>
      'No se pudieron leer los datos de activación de este dispositivo.',
    ServerFailure() => 'El servidor respondió con un error. Intentá de nuevo.',
  };

  /// Assistance flow. The two "stale state" answers get their own wording
  /// because they are not errors the user caused: the backend simply moved on,
  /// and the screen has already re-read the real state by the time this shows.
  static String forSupport(Failure failure) => switch (failure) {
    NetworkFailure() =>
      'No se pudo contactar al servidor. Verificá la conexión e intentá de nuevo.',
    ConflictFailure() || NotFoundFailure() =>
      'La solicitud cambió de estado. Se actualizó la información.',
    AuthFailure() => 'El dispositivo debe volver a activarse.',
    ValidationFailure() => 'El servidor rechazó la solicitud.',
    StorageFailure() =>
      'No se pudieron leer los datos de activación de este dispositivo.',
    ServerFailure() => 'El servidor respondió con un error. Intentá de nuevo.',
  };
}
