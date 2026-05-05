/// A function that decides whether a given error warrants another attempt.
///
/// Returning `true` means "retry". Returning `false` short-circuits retries
/// immediately, regardless of [RetryOptions.maxAttempts].
///
/// Common pattern — skip retries on auth errors:
/// ```dart
/// retryWhen: (e, _) => e is! UnauthorizedException,
/// ```
typedef RetryPredicate = bool Function(Object error, StackTrace? stackTrace);

/// Controls how many times a fetcher is retried on failure before the
/// error is propagated as a [Failure].
///
/// Pass a [RetryOptions] instance to [Cache] (global default) or to
/// individual [Cache.get] / [Cache.refresh] calls (per-call override).
///
/// New in v1.0.2.
class RetryOptions {
  const RetryOptions({
    this.maxAttempts = 3,
    this.retryWhen,
    this.delay = Duration.zero,
  }) : assert(maxAttempts >= 1, 'maxAttempts must be at least 1');

  /// A single attempt — no retries at all. This is the default for [Cache]
  /// so that v1.0.0/v1.0.1 behaviour is preserved unless the caller opts in.
  static const RetryOptions noRetry = RetryOptions(maxAttempts: 1);

  /// Retry up to 3 times with no delay, on any failure.
  static const RetryOptions defaults = RetryOptions();

  /// Maximum number of total attempts (first try + retries). Must be ≥ 1.
  final int maxAttempts;

  /// Predicate consulted before each retry. Return `false` to stop immediately.
  ///
  /// `null` means "always retry up to [maxAttempts]".
  final RetryPredicate? retryWhen;

  /// Pause between attempts. Default is [Duration.zero] (no pause).
  final Duration delay;

  /// `true` when there are more attempts remaining and the predicate allows it.
  bool shouldRetry(int attempt, Object error, StackTrace? stackTrace) {
    if (attempt >= maxAttempts) return false;
    return retryWhen == null || retryWhen!(error, stackTrace);
  }
}
