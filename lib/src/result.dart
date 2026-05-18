/// A typed outcome of an operation: either [Success] or [Failure].
///
/// `cachemesh` is Result-first — every cache and fetch operation returns a
/// `Result<T>`, mirroring the shape used by `resilify` so the two compose
/// without translation layers.
sealed class Result<T> {
  const Result();

  /// Wraps a value as a [Success].
  const factory Result.success(T value) = Success<T>;

  /// Wraps an error as a [Failure].
  const factory Result.failure(Object error, [StackTrace? stackTrace]) =
      Failure<T>;

  /// `true` if this is a [Success].
  bool get isSuccess => this is Success<T>;

  /// `true` if this is a [Failure].
  bool get isFailure => this is Failure<T>;

  /// The wrapped value, or `null` if this is a [Failure].
  T? get valueOrNull => switch (this) {
        Success<T>(:final value) => value,
        Failure<T>() => null,
      };

  /// The wrapped error, or `null` if this is a [Success].
  Object? get errorOrNull => switch (this) {
        Success<T>() => null,
        Failure<T>(:final error) => error,
      };

  /// Branches on success vs failure and returns a value of type [R].
  R fold<R>({
    required R Function(T value) onSuccess,
    required R Function(Object error, StackTrace? stackTrace) onFailure,
  }) =>
      switch (this) {
        Success<T>(:final value) => onSuccess(value),
        Failure<T>(:final error, :final stackTrace) =>
          onFailure(error, stackTrace),
      };

  /// Maps a [Success] value through [transform]; passes [Failure] through unchanged.
  Result<R> map<R>(R Function(T value) transform) => switch (this) {
        Success<T>(:final value) => Success<R>(transform(value)),
        Failure<T>(:final error, :final stackTrace) => Failure<R>(
            error,
            stackTrace,
          ),
      };
}

/// Successful outcome carrying [value].
final class Success<T> extends Result<T> {
  const Success(this.value);

  final T value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Success<T> && other.value == value);

  @override
  int get hashCode => Object.hash(Success<T>, value);

  @override
  String toString() => 'Success($value)';
}

/// Failed outcome carrying an [error] and optional [stackTrace].
final class Failure<T> extends Result<T> {
  const Failure(this.error, [this.stackTrace]);

  final Object error;
  final StackTrace? stackTrace;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Failure<T> && other.error == error);

  @override
  int get hashCode => Object.hash(Failure<T>, error);

  @override
  String toString() => 'Failure($error)';
}
