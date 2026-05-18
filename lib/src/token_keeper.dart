import 'result.dart';

/// Signature of an authenticated action: receives a valid token and returns
/// a `Result<T>`. Used together with [TokenKeeperAdapter.withValidToken].
typedef AuthenticatedAction<T> = Future<Result<T>> Function(String token);

/// Bridges any `token_keeper`-style auth manager into `cachemesh` so the
/// cache can perform token-aware fetches.
///
/// Implementations are expected to:
/// 1. Resolve a valid access token (refreshing if necessary).
/// 2. Invoke the action with that token.
/// 3. If the action returns an unauthorized failure, force-refresh the token
///    and retry **once** with the new token.
/// 4. Surface a [Failure] if no valid token can be obtained.
///
/// This mirrors `token_keeper`'s `withValidToken` semantics so cachemesh
/// can call into it without leaking auth concerns into fetchers.
///
/// New in v1.1.0.
abstract interface class TokenKeeperAdapter {
  /// Runs [action] with a valid access token, transparently refreshing on
  /// unauthorized failures and retrying once.
  Future<Result<T>> withValidToken<T>(AuthenticatedAction<T> action);
}
