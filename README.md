# cachemesh

[![pub version](https://img.shields.io/pub/v/cachemesh.svg)](https://pub.dev/packages/cachemesh)
[![pub points](https://img.shields.io/pub/points/cachemesh)](https://pub.dev/packages/cachemesh/score)
[![pub likes](https://img.shields.io/pub/likes/cachemesh)](https://pub.dev/packages/cachemesh/score)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![CI](https://github.com/himanshulahoti20/cachemesh/actions/workflows/dart_ci.yml/badge.svg?branch=main&cache_bust=1)

[![Flutter ≥3.10](https://img.shields.io/badge/flutter-%E2%89%A53.10-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart ≥3.5](https://img.shields.io/badge/dart-%E2%89%A53.3-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![platforms](https://img.shields.io/badge/platform-android%20%7C%20ios%20%7C%20macos%20%7C%20web%20%7C%20linux%20%7C%20windows-lightgrey)](https://pub.dev/packages/token_keeper)

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
  cachemesh: ^2.1.0
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

## Persistence & offline-first *(v1.2.0)*

Make the cache survive app restarts. Plug in a `PersistentStore`, register a
`CacheCodec<T>` per key-prefix, and `hydrate()` on startup.

```dart
import 'package:cachemesh/cachemesh.dart';
import 'package:cachemesh/cachemesh_io.dart'; // JsonFileStore (dart:io)

final cache = Cache(
  persistentStore: JsonFileStore.atPath('/path/to/cache.json'),
);

// Teach the cache how to (de)serialize values under the 'user:' prefix.
cache.registerCodec<User>(
  'user:',
  CacheCodec(
    encode: (u) => u.toJson(),
    decode: (j) => User.fromJson(j as Map<String, dynamic>),
  ),
);

// On startup — restore cached data instantly (expired entries are pruned).
final restored = await cache.hydrate();

// Reads/writes work as usual; successful writes are persisted in the
// background. Only keys with a registered codec are written to disk.
await cache.get<User>(
  key: 'user:1',
  fetch: () => api.fetchUser(1),
  policy: CachePolicy.networkFirst, // offline-first: fall back to cache
);

await cache.flush(); // optional durability checkpoint (e.g. on app pause)
```

Bring your own backend by implementing `PersistentStore` (Hive, sqflite,
`shared_preferences`, …). `InMemoryPersistentStore` is provided for tests.

### Cache metrics *(v1.2.0)*

```dart
final m = cache.metrics;
print(m);          // CacheMetrics(hits: 12, misses: 3, ... hitRate: 80.0%)
m.hitRate;         // 0.0–1.0
m.lookups;         // hits + misses
cache.resetMetrics();
```

## Unified data pipeline *(v2.0.0)*

Define an endpoint once, use it everywhere — no more repeating
`cache.get(key: ..., fetch: ...)` at every call site.

```dart
final users = cache.endpoint<int, User>(
  key: (id) => 'user:$id',
  fetch: (id) => api.fetchUser(id),
  policy: CachePolicy.staleWhileRevalidate,
  ttl: const Duration(minutes: 5),
);

await users(42);        // cached read
users.watch(42);        // reactive stream
await users.refresh(7); // force refresh
users.invalidate(7);    // drop this entry
users.invalidateAll();  // drop every key this endpoint produced
```

Authenticated endpoints route every fetch through the configured
`TokenKeeperAdapter` and default to `CacheScope.user`:

```dart
final cache = Cache(tokenKeeper: myKeeper);
cache.setActiveUser('alice');

final me = cache.authenticatedEndpoint<int, User>(
  key: (id) => 'me:$id',
  fetch: (id, token) => api.me(id, token),
);

await me(0);            // cached, per-user, token-aware
```

## Bounded caches, tags & direct writes *(v2.1.0)*

```dart
// Cap memory: least-recently-used entries are evicted past 500.
final cache = Cache(maxEntries: 500);

// Tag entries by concern, invalidate them together.
await cache.get(key: 'feed:1', fetch: loadFeed, tags: {'feed'});
cache.invalidateTag('feed');                        // → number dropped

// Write without a fetch (seed / optimistic update).
cache.set('user:1', user, tags: {'user'});
cache.update<User>('user:1', (u) => u.copyWith(name: 'New'));
cache.invalidateWhere((k) => k.startsWith('user:'));

// Get the current value first, then live updates — ideal for UI.
cache.watch<User>('user:1', emitCurrent: true).listen(render);
```

- Eviction also removes the entry from a `PersistentStore`, bumps
  `metrics.evictions`, and fires `CacheLogger.onEvict`.
- `set`/`update` notify `watch` subscribers and persist like any other write.
- Tags live in memory only; entries restored by `hydrate()` carry none.

## Reactive data graph *(v2.0.0)*

Combine multiple cache keys into one reactive stream — emits whenever any
underlying key updates:

```dart
final stream = cache.combineLatest<DashboardVm>(
  ['user:42', 'feed:home', 'notifications:unread'],
  (values) => DashboardVm(
    user: values[0] as User,
    feed: values[1] as Feed,
    badge: values[2] as int,
  ),
);

stream.listen((result) => ui.render(result));

// Synchronous combined read (returns null if any key is missing):
final initial = cache.peekCombined(['a', 'b'], (vs) => ...);
```

## Dev tooling *(v2.0.0)*

```dart
cache.size;            // number of entries
cache.allKeys;         // Iterable<String>
cache.contains('k');   // any entry (fresh or stale)
cache.snapshot();      // Map<key, CacheState> — no fetch

// Refresh createdAt + optionally swap TTL without re-fetching:
cache.touch('feature-flags', ttl: const Duration(hours: 1));

print(cache.debugDump());
// Cache(size=3, CacheMetrics(hits: 12, ..., hitRate: 80.0%))
//   activeUser=alice, persistent=true, tokenKeeper=true
//   - user:42                    fresh  scope=user     age=2103ms  ttl=300000ms
//   - feed:home                  fresh  scope=session  age=540ms   ttl=60000ms
//   - notifications:unread       stale  scope=user     age=70241ms ttl=30000ms
```

## Roadmap

- **1.0.1** ✅ — pluggable logger, cache state insights, safer expiry.
- **1.0.2** ✅ — failure-aware caching, retry hooks, smarter SWR.
- **1.1.0** ✅ — resilify & token_keeper integration, cache scopes.
- **1.2.0** ✅ — disk adapters, hydration, offline-first, metrics.
- **2.0.0** ✅ — unified data engine: endpoints, reactive combine, dev tooling.
- **2.1.0** ✅ — LRU `maxEntries`, tags, `set`/`update`, `watch(emitCurrent)`.

## ❤️ Support

If you find this package helpful, consider supporting:

👉 https://github.com/sponsors/himanshulahoti20


## License

See [LICENSE](LICENSE).
