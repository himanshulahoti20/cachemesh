# cachemesh

[![pub version](https://img.shields.io/pub/v/cachemesh.svg)](https://pub.dev/packages/cachemesh)
[![pub points](https://img.shields.io/pub/points/cachemesh)](https://pub.dev/packages/cachemesh/score)
[![pub likes](https://img.shields.io/pub/likes/cachemesh)](https://pub.dev/packages/cachemesh/score)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![CI](https://github.com/himanshulahoti20/cachemesh/actions/workflows/dart_ci.yml/badge.svg?branch=main&cache_bust=1)

**Cache smarter. Orchestrate data. Stay fast.**

A `Result`-first caching and data orchestration layer for Dart & Flutter apps.
Designed to compose cleanly with structured networking (`resilify`) and auth
(`token_keeper`).

## Why

`cachemesh` is the bridge between your data source and your app. It coordinates:

- **fetching** — wraps any async source
- **caching** — memory-first, pluggable storage
- **reuse** — policies that match real UI patterns
- **reactivity** — subscribe to a key, react to updates

Every operation returns a `Result<T>`, so the cache speaks the same language
as the rest of your data layer.

## Install

```yaml
dependencies:
  cachemesh: ^1.1.0
```

## Quick start

```dart
import 'package:cachemesh/cachemesh.dart';

final cache = Cache();

Future<Result<User>> loadUser(String id) {
  return cache.get<User>(
    key: 'user:$id',
    fetch: () async {
      try {
        final user = await api.fetchUser(id);
        return Success(user);
      } catch (e, st) {
        return Failure(e, st);
      }
    },
    policy: CachePolicy.staleWhileRevalidate,
    ttl: const Duration(minutes: 5),
  );
}
```

## Cache policies

| Policy | Behavior |
| --- | --- |
| `cacheFirst` | Return cached if not expired; otherwise fetch + cache. |
| `networkFirst` | Fetch fresh; fall back to cache on failure. |
| `staleWhileRevalidate` | Return cached (even if expired) immediately, refresh in background. **Flagship.** |
| `networkOnly` | Always fetch; never read from or write to the cache. |
| `cacheOnly` | Read only from cache. Returns a `CacheMissException` / `CacheExpiredException` failure if not present. |

## Reactive `watch`

Subscribe to a key and react to refreshes — perfect for UI binding.

```dart
final sub = cache.watch<User>('user:42').listen((result) {
  result.fold(
    onSuccess: (user) => render(user),
    onFailure: (err, _) => showError(err),
  );
});
```

## Single-flight

If multiple callers ask for the same key at once, only one fetch runs and
they all share the result.

```dart
// Three concurrent calls => one network request.
await Future.wait([
  cache.get(key: 'feed', fetch: fetchFeed),
  cache.get(key: 'feed', fetch: fetchFeed),
  cache.get(key: 'feed', fetch: fetchFeed),
]);
```

## Manual control

```dart
await cache.refresh(key: 'user:42', fetch: fetchUser);
await cache.prefetch(key: 'feed', fetch: fetchFeed);
cache.invalidate('user:42');
cache.clear();

// Synchronous, non-fetching read for seeding UI:
final cached = cache.peek<User>('user:42');
```

## Custom storage

`Cache` accepts any `CacheStore` implementation. v1.0.0 ships
`MemoryCacheStore`; persistent adapters land in v1.2.0.

```dart
final cache = Cache(store: MyCustomStore());
```

## Logging *(v1.0.1)*

```dart
final cache = Cache(logger: const PrintCacheLogger());
// [cachemesh] miss user:42
// [cachemesh] refresh user:42 (cacheMiss)
// [cachemesh] write user:42 ttl=300000ms
// [cachemesh] hit user:42
```

Override `CacheLogger`'s methods to ship events to your own logging stack.
Each refresh comes with a `RefreshSource` (`cacheMiss`, `policy`,
`background`, `refresh`, `prefetch`) so you can filter the noisy ones.

## Retry hooks *(v1.0.2)*

```dart
final cache = Cache(
  // Cache-wide default: retry up to 3 times on any failure.
  retryOptions: const RetryOptions(maxAttempts: 3),
);

// Per-call override: skip retries on auth errors.
await cache.get<User>(
  key: 'user:42',
  fetch: fetchUser,
  retryOptions: RetryOptions(
    maxAttempts: 3,
    retryWhen: (e, _) => e is! UnauthorizedException,
    delay: const Duration(milliseconds: 200),
  ),
);
```

`RetryOptions.noRetry` (single attempt, no delay) is the default — existing
code is unaffected.

## Failure-aware caching *(v1.0.2)*

```dart
// Cache a rate-limit failure for 30 s to avoid hammering the API.
await cache.get<Feed>(
  key: 'feed',
  fetch: fetchFeed,
  policy: CachePolicy.cacheFirst,
  cacheFailures: true,
  ttl: const Duration(seconds: 30),
);

// Check state without triggering a fetch.
if (cache.hasCachedFailure('feed')) showErrorBanner();
```

A successful re-fetch automatically clears the cached failure. `invalidate`
and `clear` also remove failure entries.

## Smarter SWR *(v1.0.2)*

`staleWhileRevalidate` now only kicks off a background refresh when the entry
is **stale**. Fresh entries are served without network traffic. Pass
`alwaysRevalidate: true` to refresh even when fresh:

```dart
await cache.get<Feed>(
  key: 'feed',
  fetch: fetchFeed,
  policy: CachePolicy.staleWhileRevalidate,
  alwaysRevalidate: true,
);
```

## Cache state insights *(v1.0.1)*

```dart
final state = cache.inspect<User>('user:42');
if (state.isMissing) showSkeleton();
else if (state.isStale) showWithStaleBanner(state.value!);
else showFresh(state.value!);

state.age;          // Duration since the entry was written
state.timeToExpiry; // negative if past TTL
state.expiresAt;    // null if no TTL
```

## Ecosystem integration *(v1.1.0)*

### Resilify

`resilify` already returns `Future<Result<T>>`, so any resilify pipeline plugs
straight into the cache — no wrapping. The `ResilifySource<T>` typedef is just
a self-documenting alias for `Fetcher<T>`:

```dart
final api = ResilifyApi(...);

// Use as a regular fetcher:
await cache.get<User>(
  key: 'user:1',
  fetch: () => api.fetchUser(1),
  policy: CachePolicy.staleWhileRevalidate,
);
```

### Token-aware fetching with `token_keeper`

Wire `token_keeper`'s `withValidToken` into the cache by implementing
`TokenKeeperAdapter`. `Cache.getAuthenticated` passes a valid token to the
fetcher; the adapter is responsible for refreshing on unauthorized once.

```dart
class MyTokenKeeperAdapter implements TokenKeeperAdapter {
  MyTokenKeeperAdapter(this.keeper);
  final TokenKeeper keeper;

  @override
  Future<Result<T>> withValidToken<T>(AuthenticatedAction<T> action) =>
      keeper.withValidToken(action); // delegate to your real keeper
}

final cache = Cache(tokenKeeper: MyTokenKeeperAdapter(myKeeper));

final me = await cache.getAuthenticated<User>(
  key: 'me',
  fetch: (token) => api.me(token), // already returns Future<Result<User>>
);
```

`getAuthenticated` defaults to `CacheScope.user` so a user switch
automatically wipes per-user data.

### Cache scopes & lifecycle

```dart
enum CacheScope { global, session, user }
```

| Scope | When it's cleared |
| --- | --- |
| `global` | Only by explicit `invalidate` / `clear`. |
| `session` | On `endSession()`. |
| `user` | On `setActiveUser(otherId)` or `endSession()`. Requires an active user. |

```dart
cache.setActiveUser('alice');

await cache.get<User>(
  key: 'me',
  fetch: fetchMe,
  scope: CacheScope.user,
);
await cache.get<Feed>(
  key: 'home-feed',
  fetch: fetchFeed,
  scope: CacheScope.session,
);

// Login flow: switching users wipes alice's data, keeps app-wide globals.
cache.setActiveUser('bob');

// Logout flow: wipes session + user data, keeps globals.
cache.endSession();

// Fine-grained:
cache.clearScope(CacheScope.session);
cache.scopeOf('me'); // => CacheScope.user
```

## Roadmap

- **1.0.1** ✅ — pluggable logger, cache state insights, safer expiry.
- **1.0.2** ✅ — failure-aware caching, retry hooks, smarter SWR.
- **1.1.0** ✅ — resilify & token_keeper integration, cache scopes.
- **1.2.0** — disk adapters, hydration, offline-first.
- **2.0.0** — unified data engine + reactive data graph.

## ❤️ Support

If you find this package helpful, consider supporting:

👉 https://github.com/sponsors/himanshulahoti20


## License

See [LICENSE](LICENSE).
