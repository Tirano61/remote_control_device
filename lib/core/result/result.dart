import 'package:remote_control_device/core/error/failures.dart';

/// Minimal result type used across repository and use case boundaries so that
/// expected failures travel as values instead of exceptions.
sealed class Result<T> {
  const Result();

  /// `true` when this result carries a value.
  bool get isOk => this is Ok<T>;

  /// The value when successful, `null` otherwise.
  T? get valueOrNull => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>() => null,
  };

  /// The failure when unsuccessful, `null` otherwise.
  Failure? get failureOrNull => switch (this) {
    Ok<T>() => null,
    Err<T>(:final failure) => failure,
  };
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;
}

final class Err<T> extends Result<T> {
  const Err(this.failure);

  final Failure failure;
}
