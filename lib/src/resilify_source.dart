import 'result.dart';

/// A function that yields a `Result<T>` on demand — the building block
/// `cachemesh` uses to refresh cached values.
///
/// Because `resilify` already exposes API calls as `Future<Result<T>>`,
/// any resilify pipeline (`resilify.call`, a `Resilify` instance, a custom
/// source) plugs directly into [Cache.get] without manual try/catch wrapping:
///
/// ```dart
/// final api = ResilifyApi(...);
/// final result = await cache.get<User>(
///   key: 'user:1',
///   fetch: () => api.fetchUser(1), // already returns Future<Result<User>>
/// );
/// ```
///
/// `ResilifySource<T>` is provided as an explicit alias so call sites read
/// well when wiring resilify in. It is interchangeable with [Fetcher].
///
/// New in v1.1.0.
typedef ResilifySource<T> = Future<Result<T>> Function();
