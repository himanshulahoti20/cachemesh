# Changelog

## 2.1.0

Bounded caches, tag invalidation, direct writes — fully backward compatible
with 2.0.x.

### Bounded memory (LRU)

- **`Cache(maxEntries: n)`** — cap the in-memory store. When a write pushes the
  cache past `n` entries, the least recently used entry is evicted (reads via
  `get` hits and `peek` count as use). Eviction also removes the entry from the
  `PersistentStore`, increments `metrics.evictions`, and fires the new
  `CacheLogger.onEvict(key)`. Unbounded by default.
- `cache.maxEntries` getter.

### Tags

- **`tags: {...}`** on `get`, `getAuthenticated`, `refresh`, `prefetch`, `set`
  and on endpoints (`endpoint` / `authenticatedEndpoint`) — label entries by
  concern.
- **`cache.invalidateTag(tag)`** — drop everything carrying a tag (including
  cached failures); returns the count. `cache.tagsOf(key)` reads them back.
- Tags are in-memory only: entries restored by `hydrate()` carry none.

### Direct writes & bulk invalidation

- **`cache.set<T>(key, value, {ttl, scope, tags})`** — write without a fetch:
  seed the cache or apply an optimistic update. Notifies `watch` subscribers,
  persists, and clears any cached failure for the key.
- **`cache.update<T>(key, transform)`** — transform the current value in place,
  keeping its TTL, scope and tags. Returns the new value, or `null` (no-op)
  when the key is absent or expired.
- **`cache.invalidateWhere(test)`** — drop every key matching a predicate;
  returns the count.

### Reactive

- **`cache.watch(key, emitCurrent: true)`** — subscribers first receive the
  currently cached value (fresh or stale), then live updates. Default
  behaviour is unchanged.

## 2.0.0

Unified Data Engine — a major version, but **fully backward compatible**.
Every 1.x call site continues to work; v2.0.0 layers a higher-level pipeline,
reactive composition, and dev tooling on top.

### Unified data pipeline

- **`CacheEndpoint<P, T>`** — bundle a key-builder, fetcher, and policy once;
  reuse everywhere. Replaces the repeated `cache.get(key: ..., fetch: ...)`
  ceremony at call sites:

  ```dart
  final users = cache.endpoint<int, User>(
    key: (id) => 'user:$id',
    fetch: (id) => api.fetchUser(id),
    policy: CachePolicy.staleWhileRevalidate,
  );
  await users(42);
  users.watch(42);
  users.invalidateAll();
  ```

- **`AuthenticatedCacheEndpoint<P, T>`** — like `CacheEndpoint` but routes
  every fetch through the configured `TokenKeeperAdapter` (defaults to
  `CacheScope.user`). Wire your `resilify` calls + `token_keeper` once and
  the rest of the app just sees `await me(id)`.
- Endpoints track `ownedKeys` so `invalidateAll()` only drops their entries,
  not the whole cache.

### Reactive data graph

- **`cache.combineLatest<R>(keys, combine)`** — single-subscription stream
  that emits whenever any underlying key updates. Failures propagate; missing
  values delay the first emission until every key has data. Combine-thrown
  exceptions are wrapped as `Failure`.
- **`cache.peekCombined<R>(keys, combine)`** — synchronous combined read for
  seeding UI before subscribing.

### Dev tooling & introspection

- **`cache.snapshot()`** — `Map<String, CacheState>` of every entry, no fetch.
- **`cache.debugDump()`** — pretty-printed multi-line summary including
  metrics, active user, persistence flag, and per-entry freshness/scope/age.
- **`cache.size`**, **`cache.allKeys`**, **`cache.contains(key)`** —
  zero-cost introspection.
- **`cache.touch(key, {ttl})`** — refresh `createdAt` (and optionally swap
  TTL) without re-fetching, for when out-of-band evidence confirms freshness.

### Bug fixes

- **`Cache.dispose()` now awaits `flush()` first** so persistence writes
  in flight at shutdown actually land on disk. Previously, calling
  `dispose()` immediately after a write could abandon the pending op.
- **`clearScope(CacheScope.global)`** documented as a no-op: global entries
  aren't tracked in the scope index (absence *is* global). Use `clear()` to
  drop globals too.

### Notes

- Listed as a major version because of the *architectural* additions
  (endpoint as the new primary abstraction). The 1.x surface — `get`,
  `refresh`, `watch`, `invalidate`, `setActiveUser`, etc. — is untouched.
- Memory cost of v2.0.0: each endpoint keeps a `Set<String>` of its owned
  keys for `invalidateAll`. Skip the endpoint API and the cost is zero.

## 1.2.0

Persistence & offline support — no breaking changes.

- **Pluggable disk persistence**: new `PersistentStore` async interface plus
  two implementations — `InMemoryPersistentStore` (tests/demos) and
  `JsonFileStore` (file-backed, `dart:io`). `JsonFileStore` lives in a separate
  entry point, `package:cachemesh/cachemesh_io.dart`, so the core library stays
  web-compatible. Bring your own backend (Hive, sqflite, shared_preferences) by
  implementing `PersistentStore`.
- **Typed serialization**: register a `CacheCodec<T>` per key-prefix via
  `Cache.registerCodec`. Only keys with a matching codec are persisted; the
  longest matching prefix wins. Write-through is fire-and-forget and never
  blocks the read path — call `Cache.flush()` for a durability checkpoint.
- **Hydration**: `Cache.hydrate()` restores persisted entries into memory at
  startup, skipping (and pruning) expired records. User-scoped records remember
  their owner, so a later `setActiveUser` correctly clears another account's
  restored data.
- **Offline-first**: persistence + `CachePolicy.networkFirst` (fall back to
  cache on failure) + `cacheFailures` gives restart-safe, network-tolerant
  reads. See `example/persistence_offline_example.dart`.
- **Cache metrics**: `Cache.metrics` exposes a `CacheMetrics` snapshot
  (hits, misses, writes, refreshes, errors, evictions, plus `lookups` and
  `hitRate`). `Cache.resetMetrics()` zeroes the counters.
- `Cache.invalidate` / `clear` now propagate to the persistent store, and
  `Cache.isPersistent` reports whether a store is configured.
- **Behaviour refinement**: `setActiveUser` now clears user-scoped entries that
  don't belong to the incoming user (previously only the immediately-preceding
  user). This is strictly safer and makes multi-account hydration correct.

## 1.1.0

Ecosystem integration — no breaking changes.

- **`ResilifySource<T>` typedef**: alias for `Fetcher<T>` so resilify pipelines
  read naturally at call sites. Any function returning `Future<Result<T>>`
  plugs straight into `Cache.get` — no manual try/catch wrapping required.
- **`TokenKeeperAdapter` interface**: bridges `token_keeper`'s
  `withValidToken` flow into the cache. Pass an adapter via
  `Cache(tokenKeeper: ...)` and use the new `Cache.getAuthenticated`
  method — fetchers receive a valid token and the adapter is responsible for
  refreshing on unauthorized once.
- **Cache scopes**: new `CacheScope` enum (`global` / `session` / `user`).
  `Cache.get`, `refresh`, and `prefetch` accept an optional `scope:`.
  `Cache.scopeOf(key)` reports the recorded scope. User-scoped reads require
  `Cache.setActiveUser(id)` to be called first.
- **Auto invalidation hooks**:
  - `Cache.setActiveUser(userId)` — clears entries belonging to the previous
    user when the active user changes; no-op if unchanged.
  - `Cache.endSession()` — drops both session- and user-scoped entries and
    unsets the active user. Call from your logout flow.
  - `Cache.clearScope(scope)` — fine-grained, drop a single scope.
- **`CacheLogger.onScopeCleared`**: new lifecycle event with the reason
  (`setActiveUser`, `endSession`, `clearScope:<name>`) and the list of
  removed keys. Only fires when there is at least one key to report.
- `Cache.invalidate` and `Cache.clear` now also clean up scope bookkeeping.

## 1.0.2

Smarter Result integration — no breaking changes.

- **Failure-aware caching**: pass `cacheFailures: true` to `Cache` or to individual
  `get` / `refresh` calls to store failures in the cache (with TTL). The cached
  failure is returned on the next lookup instead of hitting the network. A
  successful re-fetch clears the stored failure automatically.
  `Cache.hasCachedFailure(key)` lets you check the state without fetching.
- **Retry hooks**: new `RetryOptions` type (`maxAttempts`, `retryWhen`, `delay`).
  Set a cache-wide default via `Cache(retryOptions: ...)` and override per call.
  `RetryOptions.noRetry` (single attempt) is the default, so existing code is
  unaffected. Built-in `retryWhen` predicate pattern makes it easy to skip
  retries on specific error types (e.g. auth errors).
- **Smarter SWR revalidation**: `staleWhileRevalidate` now only kicks off a
  background refresh when the cached entry is actually stale. Pass
  `alwaysRevalidate: true` to restore the pre-1.0.2 behaviour.
- **Cleaner failure propagation**: returned `Failure` and thrown exceptions both
  flow through the same retry loop and `CacheLogger.onError` call; the original
  error type and stack trace are preserved throughout.

## 1.0.1

Stability & observability — no breaking changes.

- **Cache logger**: pluggable `CacheLogger` (hits, misses, writes, refreshes,
  invalidations, clears, errors) with `RefreshSource` for filtering. Includes
  `PrintCacheLogger` for quick wiring.
- **Cache state insights**: new `Cache.inspect<T>(key)` returns a `CacheState<T>`
  snapshot — `isPresent`, `isFresh`, `isStale`, `age`, `timeToExpiry`, `expiresAt`.
- **Safer expiry**: SWR no longer kicks off a redundant background refresh
  while one is already in flight. Tightens single-flight semantics.
- **Better error propagation**: fetcher failures (returned `Failure` *or*
  thrown exceptions) are routed through `CacheLogger.onError` with their
  original stack trace.

## 1.0.0

Initial release.

- `Result<T>` sealed type (`Success<T>` / `Failure<T>`) with `fold` and `map`.
- `Cache` with five policies: `cacheFirst`, `networkFirst`,
  `staleWhileRevalidate`, `networkOnly`, `cacheOnly`.
- In-memory `MemoryCacheStore` with per-entry TTL.
- Single-flight deduplication of concurrent fetches per key.
- Reactive `watch(key)` broadcast streams.
- Manual control: `refresh`, `prefetch`, `invalidate`, `clear`, `peek`.
- Pluggable `CacheStore` interface (disk adapters land in 1.2.0).
