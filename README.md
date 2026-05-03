# cachemesh

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
  cachemesh: ^1.0.1
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

## Roadmap

- **1.0.1** ✅ — pluggable logger, cache state insights, safer expiry.
- **1.0.2** — failure-aware caching, retry hooks.
- **1.1.0** — `resilify` & `token_keeper` integration, cache scopes.
- **1.2.0** — disk adapters, hydration, offline-first.
- **2.0.0** — unified data engine + reactive data graph.

## License

See [LICENSE](LICENSE).
